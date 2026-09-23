[CmdletBinding()]
param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Disposable hosted runner only.' }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupWindows {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public class Window { public long Handle; public string Title; public string ClassName; public bool Visible; public bool Minimized; public Rect Bounds; }
    public static Window[] Read(int pid) {
        var list = new List<Window>();
        EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h,out p); if(p != pid) return true;
            var title=new StringBuilder(2048); var cls=new StringBuilder(256); GetWindowText(h,title,title.Capacity); GetClassName(h,cls,cls.Capacity);
            Rect r; GetWindowRect(h,out r); list.Add(new Window { Handle=h.ToInt64(),Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(h),Minimized=IsIconic(h),Bounds=r }); return true;
        },IntPtr.Zero); return list.ToArray();
    }
}
'@
$started = Get-Date
$record = [ordered]@{ startedUtc=$started.ToUniversalTime().ToString('o'); executable=$Executable; passed=$false; samples=@(); automation=@() }
$process = $null
try {
    $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru
    $record.processId = $process.Id
    foreach ($delay in @(3,7,20)) {
        Start-Sleep -Seconds $delay
        $process.Refresh()
        $sample = [ordered]@{ elapsedSeconds=[math]::Round(((Get-Date)-$started).TotalSeconds,1); exited=$process.HasExited }
        if ($process.HasExited) { $sample.exitCode=$process.ExitCode; $record.samples += $sample; break }
        $sample.responding=$process.Responding
        $sample.windows=@([StartupWindows]::Read($process.Id))
        $record.samples += $sample
    }
    $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap=New-Object System.Drawing.Bitmap($screen.Width,$screen.Height)
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$bitmap.Size); $bitmap.Save((Join-Path $OutputDirectory 'startup-desktop.png'),[System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
    $process.Refresh()
    if ($process.HasExited) { throw "Published app exited before its main window was ready (exit $($process.ExitCode))." }
    $windows=@([StartupWindows]::Read($process.Id) | Where-Object Visible)
    foreach ($window in $windows) {
        $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.Handle)
        $children=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        $controls=@()
        foreach ($child in $children) {
            $controls += [ordered]@{ name=$child.Current.Name; type=$child.Current.ControlType.ProgrammaticName; enabled=$child.Current.IsEnabled; offscreen=$child.Current.IsOffscreen }
        }
        $record.automation += [ordered]@{ title=$window.Title; handle=$window.Handle; controls=$controls }
    }
    $main=@($windows | Where-Object { $_.Title -ceq 'ScreenTrail' -and -not $_.Minimized -and ($_.Bounds.Right-$_.Bounds.Left) -ge 600 -and ($_.Bounds.Bottom-$_.Bounds.Top) -ge 400 })
    $mainHandles=@($main | ForEach-Object { $_.Handle })
    $mainUi=@($record.automation | Where-Object { $_.handle -in $mainHandles })
    $search=@($mainUi | ForEach-Object { $_.controls } | Where-Object { $_.name -eq '최근 샷 검색' -and $_.type -eq 'ControlType.Edit' -and $_.enabled -and -not $_.offscreen })
    if ($main.Count -ne 1 -or $search.Count -ne 1 -or -not $process.Responding) { throw 'No responsive visible ScreenTrail dashboard with the expected search control.' }
    $record.passed=$true
    Write-Host 'PASS: Published ScreenTrail dashboard is visible, responsive, and still running after 30 seconds.'
} catch {
    $record.failure=$_.Exception.Message
    throw
} finally {
    $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'startup-result.json') -Encoding UTF8
    $events=@(Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$started } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -in @('.NET Runtime','Application Error','Windows Error Reporting') -and $_.Message -match 'ScreenTrail' } | Select-Object TimeCreated,Id,ProviderName,Message)
    ConvertTo-Json -InputObject $events -Depth 5 | Set-Content (Join-Path $OutputDirectory 'startup-events.json') -Encoding UTF8
    $logs=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs'
    if (Test-Path $logs) { Get-ChildItem $logs -File | Copy-Item -Destination $OutputDirectory -Force }
    if ($null -ne $process) { if (-not $process.HasExited) { $process.Kill(); $null=$process.WaitForExit(10000) }; $process.Dispose() }
}
