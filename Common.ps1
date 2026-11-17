$shadowHostRootPath = Join-Path $env:TEMP "ShadowHost"
$sendConsoleCtrlCScriptPath = Join-Path $PSScriptRoot "Send-ConsoleCtrlC.ps1"

function Get-FilePathOrDefault ($fileOrDirectoryPath, [string[]]$fileNameMasks) {
    if (Test-Path $fileOrDirectoryPath -PathType Leaf) { return $fileOrDirectoryPath }
    if (!(Test-Path $fileOrDirectoryPath -PathType Container)) {
        throw "Invalid path '$fileOrDirectoryPath'"
    }
    $pathsToCheck = $fileNameMasks | ForEach-Object { Join-Path $fileOrDirectoryPath $_ }
    $fileName =
        Get-ChildItem $pathsToCheck `
        | Select-Object -ExpandProperty Name -First 1
    return $fileName ? (Join-Path $fileOrDirectoryPath $fileName) : $null
}

function Get-ProjectFilePath($projectPath) {
    $result = Get-FilePathOrDefault $projectPath '*.csproj'
    if ($null -eq $result) { throw "Project file with extension .csproj is not found in $projectPath" }
    return $result
}

function ResolveProjectProperty($projectFilePath, $propertyName) {
    if (!(Test-Path $projectFilePath -PathType Leaf)) {
        throw "File $projectFilePath does not exist"
    }

    $compositeContent = GetProjectCompositeContent $projectFilePath
    [array]::Reverse($compositeContent)

    function GetProperty($propertyName) {
        $propertyPattern = "<$propertyName>([^\<]+)</$propertyName>"
        $originalPropertyName = [regex]::match($compositeContent, $propertyPattern).Groups[1].Value
        [regex]::replace(
            $originalPropertyName,
            "\$\((\w+)\)",
            { param($match) GetProperty($match.Groups[1].Value) })
    }

    $result = GetProperty $propertyName
    if (!$result) { return $null }
    $result
}

function GetProjectCompositeContent($projectFilePath) {
    $fullProjectFilePath = Resolve-Path $projectFilePath
    $result = Get-Content -Path $fullProjectFilePath
    $path = Split-Path $fullProjectFilePath -Parent
    while ($path) {
        $sharedProjectFilePath = Join-Path $path "Directory.Build.props"
        if (Test-Path $sharedProjectFilePath -PathType Leaf) {
            $result = (Get-Content -Path $sharedProjectFilePath) + $result
        }
        $path = Split-Path $path -Parent
    }
    @(GetPredefinedProjectContent $fullProjectFilePath) + $result
}

function GetPredefinedProjectContent($projectFilePath) {
    $projectFileName = Split-Path $projectFilePath -Leaf
    $projectName = [IO.Path]::GetFileNameWithoutExtension($projectFileName)
    $predefinedProperties = @{
        MSBuildProjectName = $projectName
        AssemblyName = $projectName
    }
    PropertiesToXml $predefinedProperties
}

function PropertiesToXml($properties) {
    $body = $properties.Keys | ForEach-Object { "<$_>$($properties[$_])</$_>" }
    "<PropertyGroup>$body</PropertyGroup>"
}

function Get-ProjectOutputPath($projectPath, $configuration = "Debug") {
    $projectFilePath = (Resolve-Path (Get-ProjectFilePath $projectPath)).Path
    $projectDirectoryPath = Split-Path $projectFilePath -Parent

    $framework = ResolveProjectProperty $projectFilePath "TargetFramework"
    if (!$framework) {
        throw "TargetFramework is not resolved for '$projectFilePath'. Multi-targeted projects are not supported."
    }

    @{
        ProjectName = [IO.Path]::GetFileNameWithoutExtension($projectFilePath)
        ProjectFilePath = $projectFilePath
        ProjectDirectoryPath = $projectDirectoryPath
        AssemblyName = ResolveProjectProperty $projectFilePath "AssemblyName"
        Framework = $framework
        OutputPath = Join-Path $projectDirectoryPath "bin\$configuration\$framework"
    }
}

function Get-ServiceLaunchSettings($projectDirectoryPath, $launchProfile) {
    $launchSettingsPath = Join-Path $projectDirectoryPath "Properties\launchSettings.json"
    if (!(Test-Path $launchSettingsPath -PathType Leaf)) { return $null }

    $launchSettings = Get-Content $launchSettingsPath -Raw | ConvertFrom-Json -AsHashtable
    $profiles = $launchSettings.profiles
    if (!$profiles -or !$profiles.Count) {
        throw "No launch profiles are defined in '$launchSettingsPath'"
    }

    # Visual Studio defaults to the first declared profile; ConvertFrom-Json keeps the JSON order.
    $launchProfile = $launchProfile ?? @($profiles.Keys)[0]
    $selectedProfile = $profiles[$launchProfile]
    if (!$selectedProfile) {
        throw "Launch profile '$launchProfile' is not found in '$launchSettingsPath'"
    }

    # An IIS Express profile keeps its bindings in iisSettings instead of in the profile itself.
    $urls = $selectedProfile.commandName -eq "IISExpress" `
        ? (Get-IisExpressUrl $launchSettings $launchSettingsPath)
        : ("$($selectedProfile.applicationUrl)" -split ";")

    @{
        Name = $launchProfile
        Urls = @($urls | Where-Object { $_ } | ForEach-Object { $_.TrimEnd("/") })
        EnvironmentVariables = $selectedProfile.environmentVariables
    }
}

function Get-IisExpressUrl($launchSettings, $launchSettingsPath) {
    $iisExpress = $launchSettings.iisSettings.iisExpress
    if (!$iisExpress) {
        throw "Section iisSettings.iisExpress is not found in '$launchSettingsPath'"
    }

    $urls = @($iisExpress.applicationUrl)
    if ($iisExpress.sslPort) { $urls += "https://localhost:$($iisExpress.sslPort)" }
    $urls
}

function Get-ShadowRootPath($projectName) {
    Join-Path $shadowHostRootPath $projectName
}

function Get-ShadowSlotPath($projectName, $slot) {
    Join-Path (Get-ShadowRootPath $projectName) $slot
}

function Copy-ToShadowSlot($sourceDirectoryPath, $slotDirectoryPath) {
    # /MIR deletes anything the source lacks, so never let it point outside the shadow root.
    if (!$slotDirectoryPath.StartsWith($shadowHostRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to mirror into '$slotDirectoryPath' outside of '$shadowHostRootPath'"
    }

    robocopy $sourceDirectoryPath $slotDirectoryPath /MIR /NFL /NDL /NJH /NJS /NP /R:3 /W:1 | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($robocopyExitCode -ge 8) {
        throw "robocopy failed with code $robocopyExitCode copying '$sourceDirectoryPath' to '$slotDirectoryPath'"
    }
}

function Test-OutputChanged($sourceDirectoryPath, $slotDirectoryPath, $assemblyName) {
    $sourceAssemblyPath = Join-Path $sourceDirectoryPath "$assemblyName.dll"
    if (!(Test-Path $sourceAssemblyPath -PathType Leaf)) {
        throw "Build output '$sourceAssemblyPath' is not found. Build the project first."
    }

    $slotAssemblyPath = Join-Path $slotDirectoryPath "$assemblyName.dll"
    if (!(Test-Path $slotAssemblyPath -PathType Leaf)) { return $true }

    $sourceAssembly = Get-Item $sourceAssemblyPath
    $slotAssembly = Get-Item $slotAssemblyPath
    $sourceAssembly.LastWriteTimeUtc -ne $slotAssembly.LastWriteTimeUtc -or
        $sourceAssembly.Length -ne $slotAssembly.Length
}

function Get-ServiceStatePath($projectName) {
    Join-Path (Get-ShadowRootPath $projectName) "state.json"
}

function Get-ServiceLockPath($projectName) {
    Join-Path (Get-ShadowRootPath $projectName) "state.lock"
}

# Held open (not deleted) for the supervisor's lifetime; the OS releases it even on a hard crash,
# so acquiring it is an atomic single-owner check that a separate check-then-write can't provide.
function Lock-ServiceState($projectName) {
    $lockPath = Get-ServiceLockPath $projectName
    New-Item (Get-ShadowRootPath $projectName) -ItemType Directory -Force | Out-Null
    try {
        [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        $null
    }
}

function Unlock-ServiceState($lockHandle) {
    if ($lockHandle) { $lockHandle.Dispose() }
}

function Test-ProcessIdentity($processId, $startTime, $processName) {
    if (!$processId) { return $false }

    $process = Get-Process -Id $processId -ErrorAction Ignore
    if (!$process) { return $false }
    $expectedStartTime = $startTime -as [datetime]
    if ($startTime) {
        if (!$expectedStartTime) { return $false }
        # An in-place PowerShell update can rename the running executable without replacing the process.
        return [Math]::Abs(($expectedStartTime.ToUniversalTime() - $process.StartTime.ToUniversalTime()).TotalSeconds) -le 1
    }
    if ($processName -and $process.ProcessName -ne $processName) { return $false }
    $true
}

function Write-ServiceState($projectName, $state) {
    $statePath = Get-ServiceStatePath $projectName
    New-Item (Split-Path $statePath -Parent) -ItemType Directory -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding utf8
}

function Read-ServiceState($projectName) {
    $statePath = Get-ServiceStatePath $projectName
    if (!(Test-Path $statePath -PathType Leaf)) { return $null }

    $state = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
    if (!(Test-ProcessIdentity $state.supervisorPid $state.supervisorStartTime $state.supervisorName)) {
        return $null
    }
    $state
}

function Find-ServiceState($projectFilePath) {
    $projectFilePath = (Resolve-Path $projectFilePath).Path
    $projectDirectoryPath = Split-Path $projectFilePath -Parent
    $supervisorScriptPath = Join-Path $PSScriptRoot "Invoke-ShadowHost.ps1"
    $scriptPattern = '(?i)(?:^|\s)-File\s+(?:"{0}"|{0})(?=\s|$)' -f [regex]::Escape($supervisorScriptPath)
    $projectPattern = '(?i)(?:^|\s)-projectPath\s+(?:"([^"]+)"|(\S+))'

    $supervisors = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction Stop | Where-Object {
        $commandLine = $_.CommandLine -replace '/', '\'
        if ($commandLine -notmatch $scriptPattern) { return $false }
        $projectArgument = [regex]::Match($commandLine, $projectPattern)
        if (!$projectArgument.Success) { return $false }
        $candidatePath = $projectArgument.Groups[1].Success `
            ? $projectArgument.Groups[1].Value : $projectArgument.Groups[2].Value
        $candidatePath = $candidatePath.TrimEnd('\')
        $candidatePath -eq $projectFilePath -or $candidatePath -eq $projectDirectoryPath
    })
    if (!$supervisors) { return $null }
    if ($supervisors.Count -gt 1) {
        throw "Multiple shadow host supervisors were found for '$projectFilePath'. Refusing to choose one."
    }

    $supervisor = $supervisors[0]
    if (!(Test-ProcessIdentity $supervisor.ProcessId $supervisor.CreationDate)) { return $null }

    $projectName = [IO.Path]::GetFileNameWithoutExtension($projectFilePath)
    $assemblyName = ResolveProjectProperty $projectFilePath "AssemblyName"
    $appHostPaths = @()
    $assemblyPatterns = @()
    foreach ($slot in "a", "b") {
        $slotPath = Get-ShadowSlotPath $projectName $slot
        $appHostPaths += Join-Path $slotPath "$assemblyName.exe"
        $assemblyPath = Join-Path $slotPath "$assemblyName.dll"
        $assemblyPatterns += '(?i)(?:^|\s)(?:"{0}"|{0})(?=\s|$)' -f [regex]::Escape($assemblyPath)
    }
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($supervisor.ProcessId)" -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -in $appHostPaths -or
            ($_.Name -eq "dotnet.exe" -and $_.CommandLine -match ($assemblyPatterns -join "|"))
    })
    if ($children.Count -gt 1) {
        throw "Multiple shadow host children were found for '$projectFilePath'. Refusing to choose one."
    }
    $child = $children | Select-Object -First 1
    Write-Warning "Recovering shadow host for '$projectName' from its process command line because its state is missing or stale."
    @{
        supervisorPid = $supervisor.ProcessId
        supervisorStartTime = $supervisor.CreationDate
        childPid = ${child}?.ProcessId
        childStartTime = ${child}?.CreationDate
    }
}

function Remove-ServiceState($projectName) {
    Remove-Item (Get-ServiceStatePath $projectName) -Force -ErrorAction Ignore
}

function Stop-ProcessGracefully($processId, [int] $timeoutSeconds = 10) {
    $process = Get-Process -Id $processId -ErrorAction Ignore
    if (!$process) { return }

    $signaler = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
        "-NoProfile"
        "-File"
        "`"$sendConsoleCtrlCScriptPath`""
        "-processId"
        $processId
    )
    $signaler.WaitForExit(5000) | Out-Null
    $signalSent = $signaler.HasExited -and $signaler.ExitCode -eq 0

    if (!($signalSent -and $process.WaitForExit($timeoutSeconds * 1000))) {
        Write-Warning "Process $processId did not exit gracefully. Terminating..."
        TaskKill.exe /pid $processId /t /f | Out-Null
        $process.WaitForExit(5000) | Out-Null
    }
    $global:LASTEXITCODE = 0
}
