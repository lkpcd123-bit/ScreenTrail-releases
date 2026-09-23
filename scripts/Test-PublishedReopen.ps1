[CmdletBinding()]
param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Disposable hosted runner only.' }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ReopenWindows {
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr w,IntPtr l);
}
'@
$record=[ordered]@{ scope='Published EXE: close its main window to the tray, then explicitly launch the EXE again.'; passed=$false }
$first=$null; $second=$null
try {
    $first=Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru
    Start-Sleep -Seconds 5
    $first.Refresh()
    if ($first.HasExited) { throw 'Initial app exited.' }
    $main=@([StartupWindows]::Read($first.Id) | Where-Object { $_.Title -eq 'ScreenTrail' -and $_.Visible })
    if ($main.Count -ne 1) { throw 'Initial main window is missing.' }
    $record.initialVisible=$true
    if (-not [ReopenWindows]::PostMessage([IntPtr]$main[0].Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'Could not close the main window.' }
    Start-Sleep -Seconds 2
    $first.Refresh()
    $record.aliveInTray=(-not $first.HasExited)
    $record.visibleAfterClose=@([StartupWindows]::Read($first.Id) | Where-Object { $_.Title -eq 'ScreenTrail' -and $_.Visible }).Count
    if (-not $record.aliveInTray -or $record.visibleAfterClose -ne 0) { throw 'Could not reproduce close-to-tray state.' }
    $second=Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru
    Start-Sleep -Seconds 5
    $record.firstProcessWindows=@([StartupWindows]::Read($first.Id))
    $record.secondProcessWindows=@([StartupWindows]::Read($second.Id))
    $record.duplicateDialogText=@()
    foreach ($window in @($record.secondProcessWindows | Where-Object Visible)) {
        $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.Handle)
        $children=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        foreach ($child in $children) { if ($child.Current.Name) { $record.duplicateDialogText += $child.Current.Name } }
    }
    $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap=New-Object System.Drawing.Bitmap($screen.Width,$screen.Height)
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$bitmap.Size); $bitmap.Save((Join-Path $OutputDirectory 'reopen-desktop.png'),[System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
    $visible=@($record.firstProcessWindows | Where-Object { $_.Title -eq 'ScreenTrail' -and $_.Visible -and -not $_.Minimized })
    $record.restoredExistingMainWindow=($visible.Count -eq 1)
    $record.passed=$record.restoredExistingMainWindow
    if (-not $record.passed) { throw 'Reproduced: explicit relaunch does not restore the existing hidden main window.' }
} catch {
    $record.failure=$_.Exception.Message
    throw
} finally {
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'reopen-result.json') -Encoding UTF8
    foreach ($process in @($second,$first)) { if ($null -ne $process) { $process.Refresh(); if (-not $process.HasExited) { $process.Kill(); $null=$process.WaitForExit(10000) }; $process.Dispose() } }
}
