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

function Wait-ActivationRequest {
    Write-ShadowHostLog "Lazy activation is not available yet - activating immediately."
}

function Start-ShadowChild($slotPath) {
    New-Item $logDirectoryPath -ItemType Directory -Force | Out-Null

    # Prefer the apphost exe over "dotnet <dll>" so the child shows up under its own name for debugging.
    $appHostPath = Join-Path $slotPath "$assemblyName.exe"
    $useAppHost = Test-Path $appHostPath -PathType Leaf
    $launchPath = $useAppHost ? $appHostPath : "dotnet"
    $arguments = @($(if (!$useAppHost) { "`"$(Join-Path $slotPath "$assemblyName.dll")`"" }), "--contentRoot", "`"$contentRoot`"") | Where-Object { $_ }

    Write-ShadowHostLog "Starting $launchPath $arguments"
    # Working directory matters too - some apps resolve appsettings.json via the current directory.
    # REVIEW: -RedirectStandardOutput/-RedirectStandardError truncate the log files on every reload
    # and crash-restart, so the output of the run that actually failed is lost. Append or use a
    # per-run file name.
    $childProcess = Start-Process $launchPath -ArgumentList $arguments -PassThru -WindowStyle Hidden `
        -WorkingDirectory $contentRoot `
        -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
    Write-ShadowHostLog "Running as process $($childProcess.Id). Logs: '$stdoutLogPath'"
    $childProcess
}

function Wait-ReloadOrExit($childProcess) {
    while (!$childProcess.HasExited) {
        Update-TriggerDeadline
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
# REVIEW: Check-then-write is racy - two supervisors started concurrently for the same project both
# pass this test and then clobber each other's state.json. A lock file / mutex would be safer.
if (Read-ServiceState $projectName) {
    throw "A shadow host supervisor is already running for '$projectName'. Stop it first."
}

$launchSettings = Get-ServiceLaunchSettings $project.ProjectDirectoryPath $launchProfile
$serviceUrls = $urls ?? ${launchSettings}?.Urls

$logDirectoryPath = Join-Path (Get-ShadowRootPath $projectName) "logs"
$stdoutLogPath = Join-Path $logDirectoryPath "stdout.log"
$stderrLogPath = Join-Path $logDirectoryPath "stderr.log"

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
try {
    if (!$noWatch) { $watcher = Register-OutputWatcher $outputPath }

    while ($true) {
        Write-ShadowHostState "Idle" $null $liveSlot
        if (!$eager) { Wait-ActivationRequest }

        $liveSlot = Update-ShadowSlot $liveSlot
        $liveSlotPath = Get-ShadowSlotPath $projectName $liveSlot
        $child = Start-ShadowChild $liveSlotPath
        Write-ShadowHostState "Running" $child $liveSlot

        if ((Wait-ReloadOrExit $child) -eq "Reload") {
            Write-ShadowHostLog "New build detected. Reloading..."
            Stop-ProcessGracefully $child.Id $shutdownTimeoutSeconds
            $crashTimes = @()
            $child = $null
            continue
        }

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
    if ($child -and !$child.HasExited) { Stop-ProcessGracefully $child.Id $shutdownTimeoutSeconds }
    Remove-ServiceState $projectName
    Write-ShadowHostLog "Supervisor stopped."
}
