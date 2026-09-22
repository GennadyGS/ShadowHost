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
    # REVIEW: Only the main assembly is compared, so a rebuild that changes just a referenced
    # project/NuGet dll leaves the shadow slot stale and the reload silently runs old dependencies.
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
    if ($processName -and $process.ProcessName -ne $processName) { return $false }

    $expectedStartTime = $startTime -as [datetime]
    if ($expectedStartTime -and [Math]::Abs(($expectedStartTime - $process.StartTime).TotalSeconds) -gt 1) {
        return $false
    }
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
