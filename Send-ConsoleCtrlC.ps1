param (
    [int] $processId
)

# Must run out-of-process: GenerateConsoleCtrlEvent hits every process attached to the target
# console, including the sender, so a supervisor signalling its own child would kill itself.

Add-Type -Namespace ShadowHostSignaler -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(int dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
'@

$native = [ShadowHostSignaler.NativeMethods]
$native::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
$native::FreeConsole() | Out-Null

# Exit code 1 tells the caller the target has no console of its own, so Ctrl+C can never reach it.
if (!$native::AttachConsole($processId)) { exit 1 }

exit ($native::GenerateConsoleCtrlEvent(0, 0) ? 0 : 2)
