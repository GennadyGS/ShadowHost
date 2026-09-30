param (
    $projectPath = '.',
    $environment = "Development",
    [Alias("c")] $configuration = "Debug",
    $launchProfile,
    [string[]] $urls,
    $contentRoot,
    $httpsProxy,
    [switch] $eager,
    [switch] $noWatch,
    [int] $debounceMilliseconds = 1500,
    [int] $shutdownTimeoutSeconds = 10
)

. $PSScriptRoot\Common.ps1

$triggerFileName = ".shadowhost-trigger"
$watcherSourceIdentifier = "ShadowHost.OutputWatcher"
$pollIntervalMilliseconds = 200
$activationPollIntervalMilliseconds = 50
$childBindTimeoutSeconds = 60
$crashWindowSeconds = 60
$crashLimit = 5

function Write-ShadowHostLog($message) {
    Write-Host "[$(Get-Date -Format "HH:mm:ss.fff")] [$projectName] $message"
}

function Register-OutputWatcher($directoryPath) {
    $watcher = [IO.FileSystemWatcher]::new($directoryPath)
    $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents = $true
    foreach ($eventName in "Created", "Changed") {
        Register-ObjectEvent $watcher $eventName -SourceIdentifier "$watcherSourceIdentifier.$eventName" | Out-Null
    }
    $watcher
}

function Unregister-OutputWatcher($watcher) {
    foreach ($eventName in "Created", "Changed") {
        Unregister-Event -SourceIdentifier "$watcherSourceIdentifier.$eventName" -ErrorAction Ignore
    }
    if ($watcher) {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
    }
}

function Update-TriggerDeadline {
    $queuedEvents = @(Get-Event | Where-Object { $_.SourceIdentifier -like "$watcherSourceIdentifier.*" })
    foreach ($queuedEvent in $queuedEvents) {
        Remove-Event -EventIdentifier $queuedEvent.EventIdentifier
        $changedFileName = Split-Path $queuedEvent.SourceEventArgs.FullPath -Leaf

        # The post-build target writes the marker once the whole output set is on disk, so act at once.
        if ($changedFileName -eq $triggerFileName) {
            $script:markerSeen = $true
            $script:triggerDeadline = [datetime]::UtcNow
            continue
        }

        # Fallback for machines without the ShadowHostReload target: wait out a quiet period instead.
        if (!$markerSeen -and ($changedFileName -like "*.dll" -or $changedFileName -like "*.exe")) {
            $script:triggerDeadline = [datetime]::UtcNow.AddMilliseconds($debounceMilliseconds)
        }
    }
}

function Test-FileReady($filePath) {
    try {
        [IO.File]::Open($filePath, "Open", "Read", "None").Dispose()
        $true
    }
    catch {
        $false
    }
}

function Test-ReloadRequired {
    if (!$triggerDeadline -or [datetime]::UtcNow -lt $triggerDeadline) { return $false }
    $script:triggerDeadline = $null

    # MSBuild may still hold the assembly when the fallback watcher fires; retry on the next tick.
    if (!(Test-FileReady (Join-Path $outputPath "$assemblyName.dll"))) {
        $script:triggerDeadline = [datetime]::UtcNow.AddMilliseconds($debounceMilliseconds)
        return $false
    }

    Test-OutputChanged $outputPath $liveSlotPath $assemblyName
}

function Update-ShadowSlot($currentSlot) {
    $slot = $currentSlot -eq "a" ? "b" : "a"
    $slotPath = Get-ShadowSlotPath $projectName $slot
    if (Test-OutputChanged $outputPath $slotPath $assemblyName) {
        Write-ShadowHostLog "Shadow copying '$outputPath' to '$slotPath'..."
        Copy-ToShadowSlot $outputPath $slotPath
    }
    $slot
}

function Get-ListenerEndpoints($serviceUrls) {
    foreach ($url in $serviceUrls) {
        if (!($url -match "^(?<scheme>https?)://(?<host>\[[^\]]+\]|[^:/]+)(:(?<port>\d+))?")) {
            throw "Cannot parse the listening url '$url'"
        }
        $port = $Matches.port ? [int] $Matches.port : ($Matches.scheme -eq "https" ? 443 : 80)
        $urlHost = $Matches.host.Trim("[", "]")

        # A wildcard binding is one dual-mode socket; a named host can resolve to both IPv4 and IPv6
        # ("localhost" does), and Kestrel binds all of them, so the idle listener must match.
        if ($urlHost -in "*", "+", "0.0.0.0", "::") {
            [Net.IPEndPoint]::new([Net.IPAddress]::IPv6Any, $port)
            continue
        }
        foreach ($address in [Net.Dns]::GetHostAddresses($urlHost)) {
            [Net.IPEndPoint]::new($address, $port)
        }
    }
}

function Get-AcceptedEndPoint($client) {
    # The address the caller actually reached is exactly what the child will bind. A dual-mode
    # listener reports it IPv4-mapped, which an IPv6-only client socket cannot connect back to.
    $localEndPoint = [Net.IPEndPoint] $client.Client.LocalEndPoint
    $address = $localEndPoint.Address.IsIPv4MappedToIPv6 `
        ? $localEndPoint.Address.MapToIPv4()
        : $localEndPoint.Address
    [Net.IPEndPoint]::new($address, $localEndPoint.Port)
}

function Wait-ActivationRequest {
    if (!$serviceUrls) {
        Write-ShadowHostLog "No urls are configured - starting without waiting for a connection."
        return @()
    }

    $listeners = @()
    try {
        foreach ($endpoint in Get-ListenerEndpoints $serviceUrls) {
            $listener = [Net.Sockets.TcpListener]::new($endpoint)
            if ($endpoint.Address.Equals([Net.IPAddress]::IPv6Any)) { $listener.Server.DualMode = $true }
            $listener.Start()
            $listeners += $listener
        }
        Write-ShadowHostLog "Idle. Waiting for the first connection on '$($serviceUrls -join ";")'."

        while ($true) {
            $pendingListeners = @($listeners | Where-Object { $_.Pending() })
            if ($pendingListeners) {
                # Drain everything already queued, so a browser's parallel connections survive activation.
                return @(foreach ($listener in $pendingListeners) {
                    while ($listener.Pending()) {
                        $client = $listener.AcceptTcpClient()
                        @{ Client = $client; EndPoint = Get-AcceptedEndPoint $client }
                    }
                })
            }
            Update-TriggerDeadline
            Start-Sleep -Milliseconds $activationPollIntervalMilliseconds
        }
    }
    finally {
        # Release the ports before the child tries to bind them; accepted sockets stay open.
        foreach ($listener in $listeners) { $listener.Stop() }
    }
}

function Connect-ChildEndPoint($endPoint, $childProcess) {
    $deadline = [datetime]::UtcNow.AddSeconds($childBindTimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline -and !$childProcess.HasExited) {
        $upstream = [Net.Sockets.TcpClient]::new($endPoint.AddressFamily)
        try {
            $upstream.Connect($endPoint)
            return $upstream
        }
        catch [Net.Sockets.SocketException] {
            $upstream.Dispose()
            Start-Sleep -Milliseconds 100
        }
    }
    $null
}

# Raw byte relay of the one socket that triggered activation - no HTTP parsing, so TLS passes
# through untouched. Every later connection reaches the child directly.
function Add-ConnectionRelay($pending, $childProcess) {
    $upstream = Connect-ChildEndPoint $pending.EndPoint $childProcess
    if (!$upstream) {
        Write-ShadowHostLog "Child is not listening on '$($pending.EndPoint)' - dropping the pending connection."
        $pending.Client.Close()
        return
    }

    $pending.Client.NoDelay = $true
    $upstream.NoDelay = $true
    $clientStream = $pending.Client.GetStream()
    $upstreamStream = $upstream.GetStream()
    $script:relays += @{
        Client = $pending.Client
        Upstream = $upstream
        Tasks = @($clientStream.CopyToAsync($upstreamStream), $upstreamStream.CopyToAsync($clientStream))
    }
}

function Update-ConnectionRelays([switch] $closeAll) {
    foreach ($relay in @($script:relays)) {
        # One finished direction means that peer is gone; drop the other half instead of leaking it.
        if (!$closeAll -and !($relay.Tasks | Where-Object { $_.IsCompleted })) { continue }
        $relay.Client.Close()
        $relay.Upstream.Close()
        $script:relays = @($script:relays | Where-Object { $_ -ne $relay })
    }
}

function Start-ShadowChild($slotPath) {
    New-Item $logDirectoryPath -ItemType Directory -Force | Out-Null

    # Prefer the apphost exe over "dotnet <dll>" so the child shows up under its own name for debugging.
    $appHostPath = Join-Path $slotPath "$assemblyName.exe"
    $useAppHost = Test-Path $appHostPath -PathType Leaf
    $launchPath = $useAppHost ? $appHostPath : "dotnet"
    $arguments = @($(if (!$useAppHost) { "`"$(Join-Path $slotPath "$assemblyName.dll")`"" }), "--contentRoot", "`"$contentRoot`"") | Where-Object { $_ }

    # Per-run file names so a reload or crash-restart doesn't truncate the previous run's log.
    $logTimestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $script:stdoutLogPath = Join-Path $logDirectoryPath "stdout.$logTimestamp.log"
    $script:stderrLogPath = Join-Path $logDirectoryPath "stderr.$logTimestamp.log"

    Write-ShadowHostLog "Starting $launchPath $arguments"
    # Working directory matters too - some apps resolve appsettings.json via the current directory.
    $childProcess = Start-Process $launchPath `
        -ArgumentList $arguments `
        -PassThru `
        -WindowStyle Hidden `
        -WorkingDirectory $contentRoot `
        -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
    Write-ShadowHostLog "Running as process $($childProcess.Id). Logs: '$stdoutLogPath'"
    $childProcess
}

function Wait-ReloadOrExit($childProcess) {
    while (!$childProcess.HasExited) {
        Update-TriggerDeadline
        Update-ConnectionRelays
        if (Test-ReloadRequired) { return "Reload" }
        Start-Sleep -Milliseconds $pollIntervalMilliseconds
    }
    "Exited"
}

function Write-ShadowHostState($serviceState, $childProcess, $slot) {
    Write-ServiceState $projectName @{
        state = $serviceState
        supervisorPid = $PID
        supervisorStartTime = $supervisorProcess.StartTime.ToString("o")
        supervisorName = $supervisorProcess.ProcessName
        childPid = ${childProcess}?.Id
        childStartTime = $childProcess ? $childProcess.StartTime.ToString("o") : $null
        urls = $serviceUrls
        slot = $slot
        projectPath = $projectFilePath
        logPath = $stdoutLogPath
    }
}

$project = Get-ProjectOutputPath $projectPath $configuration
$projectName = $project.ProjectName
$projectFilePath = $project.ProjectFilePath
$assemblyName = $project.AssemblyName
$outputPath = $project.OutputPath
$contentRoot = $contentRoot ?? $project.ProjectDirectoryPath

if (!(Test-Path $outputPath -PathType Container)) {
    throw "Build output '$outputPath' is not found. Build the project first."
}
$serviceLock = Lock-ServiceState $projectName
if (!$serviceLock) {
    throw "A shadow host supervisor is already running for '$projectName'. Stop it first."
}

$launchSettings = Get-ServiceLaunchSettings $project.ProjectDirectoryPath $launchProfile
$serviceUrls = $urls ?? ${launchSettings}?.Urls

$logDirectoryPath = Join-Path (Get-ShadowRootPath $projectName) "logs"
$stdoutLogPath = $null
$stderrLogPath = $null

$supervisorProcess = Get-Process -Id $PID
$markerSeen = Test-Path (Join-Path $outputPath $triggerFileName) -PathType Leaf
$triggerDeadline = $null

foreach ($variableName in $launchSettings.EnvironmentVariables.Keys) {
    Set-Item "env:$variableName" $launchSettings.EnvironmentVariables[$variableName]
}
$env:ASPNETCORE_ENVIRONMENT = $environment
if ($serviceUrls) { $env:ASPNETCORE_URLS = $serviceUrls -join ";" }
if ($httpsProxy) { $env:HTTPS_PROXY = $httpsProxy }

Write-ShadowHostLog "Launch profile '$($launchSettings.Name)', environment '$environment', urls '$($serviceUrls -join ';')'"

$liveSlot = $null
$liveSlotPath = $null
$child = $null
$crashTimes = @()
$watcher = $null
$relays = @()
try {
    if (!$noWatch) { $watcher = Register-OutputWatcher $outputPath }

    while ($true) {
        Write-ShadowHostState "Idle" $null $liveSlot
        $pendingConnections = $eager ? @() : (Wait-ActivationRequest)

        # Triggers queued while idle are moot - the copy below already takes the newest output.
        Update-TriggerDeadline
        $triggerDeadline = $null

        $liveSlot = Update-ShadowSlot $liveSlot
        $liveSlotPath = Get-ShadowSlotPath $projectName $liveSlot
        $child = Start-ShadowChild $liveSlotPath
        Write-ShadowHostState "Running" $child $liveSlot
        foreach ($pending in $pendingConnections) { Add-ConnectionRelay $pending $child }

        if ((Wait-ReloadOrExit $child) -eq "Reload") {
            Write-ShadowHostLog "New build detected. Reloading..."
            Stop-ProcessGracefully $child.Id $shutdownTimeoutSeconds
            Update-ConnectionRelays -closeAll
            $crashTimes = @()
            $child = $null
            continue
        }
        Update-ConnectionRelays -closeAll

        $exitCode = $child.ExitCode
        $child = $null
        if ($exitCode -eq 0) {
            Write-ShadowHostLog "Child exited with code 0. Stopping the supervisor."
            break
        }

        $now = [datetime]::UtcNow
        $crashTimes = @($crashTimes | Where-Object { ($now - $_).TotalSeconds -lt $crashWindowSeconds }) + $now
        Write-ShadowHostLog "Child exited unexpectedly with code $exitCode ($($crashTimes.Count) of $crashLimit within $crashWindowSeconds s). See '$stderrLogPath'."
        if ($crashTimes.Count -ge $crashLimit) {
            throw "Child failed $($crashTimes.Count) times within $crashWindowSeconds seconds. Stopping the supervisor."
        }
    }
}
finally {
    Unregister-OutputWatcher $watcher
    Update-ConnectionRelays -closeAll
    if ($child -and !$child.HasExited) { Stop-ProcessGracefully $child.Id $shutdownTimeoutSeconds }
    Remove-ServiceState $projectName
    Unlock-ServiceState $serviceLock
    Write-ShadowHostLog "Supervisor stopped."
}
