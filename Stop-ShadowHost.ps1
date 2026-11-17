param (
    $projectPath = '.',
    [int] $shutdownTimeoutSeconds = 10
)

. $PSScriptRoot\Common.ps1

$projectFilePath = Get-ProjectFilePath $projectPath
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectFilePath)

$state = Read-ServiceState $projectName
# Older stop attempts may have removed the state after an executable rename invalidated its name.
if (!$state) { $state = Find-ServiceState $projectFilePath }
if (!$state) {
    "No running shadow host is found for '$projectName'."
    Remove-ServiceState $projectName
    return
}

# The supervisor goes first, otherwise it would treat the stopped child as a crash and restart it.
"Stopping supervisor $($state.supervisorPid) of '$projectName' ..."
Stop-ProcessGracefully $state.supervisorPid $shutdownTimeoutSeconds

# The supervisor stops the child in its own finally block, but a forced kill leaves the child behind.
if (Test-ProcessIdentity $state.childPid $state.childStartTime) {
    "Stopping child process $($state.childPid) ..."
    Stop-ProcessGracefully $state.childPid $shutdownTimeoutSeconds
}

Remove-ServiceState $projectName
"Shadow host for '$projectName' is stopped."
