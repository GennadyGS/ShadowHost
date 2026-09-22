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
    [int] $shutdownTimeoutSeconds = 10,
    $windowStyle = "hidden"
)

. $PSScriptRoot\Common.ps1

$shadowHostScriptPath = Join-Path $PSScriptRoot "Invoke-ShadowHost.ps1"

# Validate the project up front so a missing/invalid path fails immediately instead of surfacing
# only in the background process's log files.
$project = Get-ProjectOutputPath $projectPath $configuration

$logDirectoryPath = Join-Path $env:TEMP "ShadowHost\SupervisorLogs"
New-Item $logDirectoryPath -ItemType Directory -Force | Out-Null
# Log names key off the absolute project path so unrelated projects never collide/overwrite each other.
$logNameSafe = $project.ProjectFilePath -replace '[\\/:]', '_'
$stdoutLogPath = Join-Path $logDirectoryPath "$logNameSafe.out.log"
$stderrLogPath = Join-Path $logDirectoryPath "$logNameSafe.err.log"

$arguments = @(
    "-NoProfile"
    "-File"; "`"$shadowHostScriptPath`""
    "-projectPath"; "`"$projectPath`""
    "-environment"; $environment
    "-configuration"; $configuration
    "-debounceMilliseconds"; $debounceMilliseconds
    "-shutdownTimeoutSeconds"; $shutdownTimeoutSeconds
)
if ($launchProfile) { $arguments += @("-launchProfile", "`"$launchProfile`"") }
if ($urls) { $arguments += @("-urls", $urls) }
if ($contentRoot) { $arguments += @("-contentRoot", "`"$contentRoot`"") }
if ($httpsProxy) { $arguments += @("-httpsProxy", $httpsProxy) }
if ($eager) { $arguments += "-eager" }
if ($noWatch) { $arguments += "-noWatch" }

Start-Process pwsh -ArgumentList $arguments -WindowStyle $windowStyle `
    -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
