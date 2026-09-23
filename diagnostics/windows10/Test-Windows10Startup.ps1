[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
$started = Get-Date
$record = [ordered]@{ schemaVersion=1; version='0.1.16'; releaseState='published compatibility prerelease'; startedUtc=$started.ToUniversalTime().ToString('o'); passed=$false; stage='environment'; installationPassed=$false; startupPassed=$false; samples=@(); notes=@(); prerequisiteActions=@() }
$installer = $null
$utf8 = New-Object Text.UTF8Encoding($true)
function Write-Json([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $ResultsDirectory $Name), (ConvertTo-Json -InputObject $Value -Depth 15), $utf8)
}
function Add-Note([string]$Message) { $record.notes += $Message }
function Get-VcState {
    $value = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if ($null -eq $value) { return @{ present=$false } }
    return @{ present=$true; installed=$value.Installed; version=$value.Version; major=$value.Major; minor=$value.Minor; build=$value.Bld; revision=$value.Rbld }
}
function Save-InstallerState {
    $items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ScreenTrail|VC_redist|vc_runtime|powershell|msiexec' } | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)
    Write-Json 'installer-processes.json' $items
    $windows = @()
    foreach ($item in $items) { $windows += [StartupWindows]::Read([int]$item.ProcessId) }
    Write-Json 'installer-windows.json' $windows
}
function Invoke-Helper([string]$Script, [string]$Arguments, [int]$TimeoutSeconds=20) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '" ' + $Arguments
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $child = [Diagnostics.Process]::Start($start)
    $null=$child.Handle
    try {
        if (-not $child.WaitForExit($TimeoutSeconds*1000)) { $child.Kill(); $null=$child.WaitForExit(5000); return $false }
        return ($child.ExitCode -eq 0)
    } finally { $child.Dispose() }
}

# Out-of-process UI Automation bounds a broken provider's response time.
$vcHelper = Join-Path $ResultsDirectory 'prerequisite-ui-helper.ps1'
[IO.File]::WriteAllText($vcHelper, @'
param([int]$InstallerId,[string]$ResultPath)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class VcNativeControls {
    public delegate bool EnumProc(IntPtr h,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p,IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumProc p,IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent,IntPtr child);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] static extern IntPtr TextMessage(IntPtr h,uint m,UIntPtr w,StringBuilder l,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW")] static extern IntPtr Message(IntPtr h,uint m,UIntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
    public class Control { public long Handle; public string Text; public string ClassName; public bool Enabled; public bool Visible; public long CheckState; }
    static bool Owned(IntPtr h,int pid) { uint owner; GetWindowThreadProcessId(h,out owner); return owner==pid; }
    static string Text(IntPtr h) { var s=new StringBuilder(257); UIntPtr value; TextMessage(h,0x000D,(UIntPtr)257,s,2,300,out value); return s.ToString(); }
    static string Class(IntPtr h) { var s=new StringBuilder(80); GetClassName(h,s,s.Capacity); return s.ToString(); }
    static long Check(IntPtr h) { UIntPtr value; return Message(h,0x00F0,UIntPtr.Zero,IntPtr.Zero,2,300,out value)==IntPtr.Zero ? -1 : (long)value.ToUInt64(); }
    static Control Read(IntPtr h) { var cls=Class(h); return new Control { Handle=h.ToInt64(),Text=Text(h),ClassName=cls,Enabled=IsWindowEnabled(h),Visible=IsWindowVisible(h),CheckState=cls.Equals("Button",StringComparison.OrdinalIgnoreCase)?Check(h):-1 }; }
    public static Control[] Windows(int pid) { var items=new List<Control>(); EnumWindows((h,l)=> { if(Owned(h,pid)&&IsWindowVisible(h)) items.Add(Read(h)); return true; },IntPtr.Zero); return items.ToArray(); }
    public static Control[] Children(int pid,long parent) { var items=new List<Control>(); var root=new IntPtr(parent); if(!Owned(root,pid)) return items.ToArray(); EnumChildWindows(root,(h,l)=> { if(Owned(h,pid)&&IsChild(root,h)) items.Add(Read(h)); return items.Count<120; },IntPtr.Zero); return items.ToArray(); }
    public static bool Click(int pid,long parent,long handle,string expectedText,bool uncheckedOnly) {
        var root=new IntPtr(parent); var child=new IntPtr(handle);
        if(!Owned(root,pid)||!Owned(child,pid)||!IsChild(root,child)||!IsWindowVisible(child)||!IsWindowEnabled(child)||!Class(child).Equals("Button",StringComparison.OrdinalIgnoreCase)||Text(child)!=expectedText) return false;
        if(uncheckedOnly&&Check(child)!=0) return false;
        SetForegroundWindow(root); UIntPtr value; return Message(child,0x00F5,UIntPtr.Zero,IntPtr.Zero,2,1000,out value)!=IntPtr.Zero;
    }
}
"@
$actions=@()
try {
    $all=@(Get-CimInstance Win32_Process)
    $descendants=@($InstallerId)
    for($level=0;$level -lt 8;$level++) {
        $next=@($all | Where-Object { $_.ParentProcessId -in $descendants -and $_.ProcessId -notin $descendants } | ForEach-Object { [int]$_.ProcessId })
        if($next.Count -eq 0) { break }; $descendants += $next
    }
    foreach($candidate in @($all | Where-Object { $_.ProcessId -in $descendants -and $_.Name -eq 'VC_redist.x64.exe' })) {
        $signature=Get-AuthenticodeSignature -LiteralPath $candidate.ExecutablePath
        if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            $actions += @{ processId=$candidate.ProcessId; action='refused-unverified-prerequisite'; signature=[string]$signature.Status }; continue
        }
        # Burn exposes owner-drawn checkboxes as UIA Pane. Use exact native button
        # handles only after validating the installer's process ancestry and signature.
        foreach($window in [VcNativeControls]::Windows([int]$candidate.ProcessId)) {
            if($window.Text -notmatch '^Microsoft Visual C\+\+.*Redistributable') { continue }
            $controls=@([VcNativeControls]::Children([int]$candidate.ProcessId,$window.Handle))
            $actions += @{ processId=$candidate.ProcessId; title=$window.Text; action='observed-native-controls'; controls=$controls }
            $installEnabled=@($controls | Where-Object { $_.ClassName -eq 'Button' -and ($_.Text -replace '&','').Trim() -eq 'Install' -and $_.Enabled -and $_.Visible }).Count -gt 0
            foreach($control in $controls) {
                $caption=($control.Text -replace '&','').Trim()
                if(-not $installEnabled -and $control.ClassName -eq 'Button' -and $caption -match '^I agree to the licen[cs]e terms and conditions\.?$' -and $control.CheckState -eq 0) {
                    $clicked=[VcNativeControls]::Click([int]$candidate.ProcessId,$window.Handle,$control.Handle,$control.Text,$true)
                    $actions += @{ action='accept-bundled-microsoft-vc-license-native'; processId=$candidate.ProcessId; handle=$control.Handle; clicked=$clicked }
                }
            }
            # Re-enumerate because accepting the checkbox enables Install immediately.
            $buttons=@([VcNativeControls]::Children([int]$candidate.ProcessId,$window.Handle) | Where-Object { $_.ClassName -eq 'Button' -and $_.Enabled -and $_.Visible })
            $installButtons=@($buttons | Where-Object { ($_.Text -replace '&','').Trim() -eq 'Install' })
            if($installButtons.Count -gt 0) {
                $control=$installButtons[0]
                $clicked=[VcNativeControls]::Click([int]$candidate.ProcessId,$window.Handle,$control.Handle,$control.Text,$false)
                $actions += @{ action='bundled-microsoft-vc-install-native'; processId=$candidate.ProcessId; handle=$control.Handle; clicked=$clicked }
            } else {
                # Close only after real installation; never dismiss an unaccepted
                # license or an installation failure just to make the parent continue.
                $installed=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
                if($null -ne $installed -and $installed.Installed -eq 1) {
                    $closeButtons=@($buttons | Where-Object { ($_.Text -replace '&','').Trim() -eq 'Close' })
                    if($closeButtons.Count -gt 0) {
                        $control=$closeButtons[0]
                        $clicked=[VcNativeControls]::Click([int]$candidate.ProcessId,$window.Handle,$control.Handle,$control.Text,$false)
                        $actions += @{ action='bundled-microsoft-vc-close-success-native'; processId=$candidate.ProcessId; handle=$control.Handle; clicked=$clicked }
                    }
                }
            }
        }
    }
} catch { $actions += @{ action='helper-error'; message=$_.Exception.Message } }
ConvertTo-Json -InputObject $actions -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@, $utf8)

$uiHelper = Join-Path $ResultsDirectory 'startup-ui-helper.ps1'
[IO.File]::WriteAllText($uiHelper, @'
param([int]$ApplicationId,[string]$ResultPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$result=@{ passed=$false; windows=@() }
try {
    $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$ApplicationId)
    $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,$condition)
    foreach($window in $windows) {
        $children=$window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        $controls=@($children | ForEach-Object { @{ name=$_.Current.Name.Substring(0,[Math]::Min(256,$_.Current.Name.Length)); type=$_.Current.ControlType.ProgrammaticName; enabled=$_.Current.IsEnabled; offscreen=$_.Current.IsOffscreen } })
        $result.windows += @{ title=$window.Current.Name; offscreen=$window.Current.IsOffscreen; enabled=$window.Current.IsEnabled; controls=$controls }
        $search=@($controls | Where-Object { $_.name -ceq '최근 샷 검색' -and $_.type -eq 'ControlType.Edit' -and $_.enabled -and -not $_.offscreen })
        if($window.Current.Name -ceq 'ScreenTrail' -and -not $window.Current.IsOffscreen -and $search.Count -eq 1) { $result.passed=$true }
    }
} catch { $result.failure=$_.Exception.Message }
ConvertTo-Json -InputObject $result -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if(-not $result.passed) { exit 1 }
'@, $utf8)

function Test-AppVariant([string]$Executable,[string]$Prefix) {
    $variant=[ordered]@{ passed=$false; executable=$Executable; samples=@(); notes=@(); arguments='' }
    $app=$null; $stderrTask=$null; $stdoutTask=$null
    $launchStarted=Get-Date
    try {
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$Executable; $startInfo.WorkingDirectory=Split-Path $Executable
        $startInfo.UseShellExecute=$false; $startInfo.RedirectStandardError=$true; $startInfo.RedirectStandardOutput=$true
        $startInfo.EnvironmentVariables['DOTNET_HOST_TRACE']='1'
        $startInfo.EnvironmentVariables['DOTNET_HOST_TRACEFILE']=Join-Path $ResultsDirectory ($Prefix+'-dotnet-host-trace.log')
        $startInfo.EnvironmentVariables['DOTNET_HOST_TRACE_VERBOSITY']='4'
        $startInfo.EnvironmentVariables['COREHOST_TRACE']='1'
        $startInfo.EnvironmentVariables['COREHOST_TRACEFILE']=Join-Path $ResultsDirectory ($Prefix+'-corehost-trace.log')
        $startInfo.EnvironmentVariables['COREHOST_TRACE_VERBOSITY']='4'
        $app=[Diagnostics.Process]::Start($startInfo)
        $null=$app.Handle
        $variant.processId=$app.Id; $variant.launchUtc=$launchStarted.ToUniversalTime().ToString('o')
        $stderrTask=$app.StandardError.ReadToEndAsync(); $stdoutTask=$app.StandardOutput.ReadToEndAsync()
        foreach ($at in @(3,10,30)) {
            $remaining=[int][Math]::Ceiling(($at-((Get-Date)-$launchStarted).TotalSeconds)*1000)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
            $app.Refresh()
            $sample=[ordered]@{ elapsedSeconds=[Math]::Round(((Get-Date)-$launchStarted).TotalSeconds,2); exited=$app.HasExited; windows=@() }
            if ($app.HasExited) { $sample.exitCode=$app.ExitCode; $sample.exitCodeHex=('0x{0:X8}' -f ($app.ExitCode -band 0xffffffffL)) }
            else { $sample.responding=$app.Responding; $sample.windows=@([StartupWindows]::Read($app.Id)) }
            $variant.samples += $sample
        }
        $app.Refresh()
        if ($app.HasExited) { throw ('Application exited before its dashboard was ready; exit '+$app.ExitCode) }
        $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap=New-Object System.Drawing.Bitmap($screen.Width,$screen.Height)
        $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$bitmap.Size); $bitmap.Save((Join-Path $ResultsDirectory ($Prefix+'-desktop.png')),[System.Drawing.Imaging.ImageFormat]::Png) }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
        $uiResult=Join-Path $ResultsDirectory ($Prefix+'-automation.json')
        $uiPassed=Invoke-Helper $uiHelper ('-ApplicationId '+$app.Id+' -ResultPath "'+$uiResult+'"') 25
        $app.Refresh()
        $windows=@([StartupWindows]::Read($app.Id) | Where-Object { $_.Visible -and -not $_.Minimized -and $_.Title -ceq 'ScreenTrail' -and ($_.Bounds.Right-$_.Bounds.Left) -ge 600 -and ($_.Bounds.Bottom-$_.Bounds.Top) -ge 400 })
        if ($app.HasExited -or -not $app.Responding -or $windows.Count -ne 1 -or -not $uiPassed) { throw 'No responsive visible dashboard with the expected enabled search edit control after thirty seconds.' }
        $variant.passed=$true
    } catch { $variant.failure=$_.Exception.Message; $variant.failureType=$_.Exception.GetType().FullName }
    finally {
        try {
            $events=@(Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$launchStarted } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -in @('.NET Runtime','Application Error','Windows Error Reporting','SideBySide') } | Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message)
            Write-Json ($Prefix+'-events.json') $events
            $variant.cetRuntimeFailureObserved=@($events | Where-Object { $_.Message -match '(?i)80131506|CET|shadow.stack' }).Count -gt 0
            $appLog=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs\app.log'
            if (Test-Path -LiteralPath $appLog) { Copy-Item -LiteralPath $appLog -Destination (Join-Path $ResultsDirectory ($Prefix+'-app.log')) -Force }
        } catch { $variant.notes += ('Event/log collection: '+$_.Exception.Message) }
        # Dispose only this disposable guest's own application after recording diagnostics.
        if ($null -ne $app) {
            try {
                $app.Refresh(); $variant.aliveAfterDiagnostics=-not $app.HasExited
                if (-not $app.HasExited) { $app.Kill(); if (-not $app.WaitForExit(10000)) { throw 'Own application did not stop before the next variant.' }; $variant.cleanedUp=$true }
                foreach ($capture in @(@{task=$stderrTask;name=$Prefix+'-stderr.txt'},@{task=$stdoutTask;name=$Prefix+'-stdout.txt'})) {
                    if ($null -ne $capture.task -and $capture.task.Wait(5000)) { [IO.File]::WriteAllText((Join-Path $ResultsDirectory $capture.name),$capture.task.Result,$utf8) }
                }
            } catch { $variant.notes += ('Process cleanup: '+$_.Exception.Message); $variant.cleanupFailed=$true; $variant.passed=$false }
            finally { $app.Dispose() }
        }
        $variant.finishedUtc=[DateTime]::UtcNow.ToString('o')
        Write-Json ($Prefix+'-result.json') $variant
    }
    return $variant
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $machine = Get-CimInstance Win32_ComputerSystem
    $record.os = @{ caption=$os.Caption; version=$os.Version; build=$os.BuildNumber; productType=$os.ProductType; architecture=$os.OSArchitecture }
    $record.machine = @{ manufacturer=$machine.Manufacturer; model=$machine.Model; memoryBytes=$machine.TotalPhysicalMemory; interactive=[Environment]::UserInteractive; is64BitProcess=[Environment]::Is64BitProcess }
    $record.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name,Manufacturer,Architecture,ProcessorId,NumberOfCores,NumberOfLogicalProcessors)
    $record.vcBefore = Get-VcState
    $record.dotnetDirectoriesBefore = @(@('C:\Program Files\dotnet','C:\Program Files (x86)\dotnet') | Where-Object { Test-Path -LiteralPath $_ })
    $record.systemVcDllsBefore = @(Get-ChildItem -Path "$env:WINDIR\System32\vcruntime140*.dll","$env:WINDIR\System32\msvcp140*.dll" -ErrorAction SilentlyContinue | ForEach-Object { @{ name=$_.Name; version=$_.VersionInfo.FileVersion } })
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 19041 -or [int]$os.BuildNumber -ge 22000 -or -not [Environment]::Is64BitOperatingSystem) { throw 'This diagnostic requires an actual x64 Windows 10 client build 19041 through 21999.' }
    if ($machine.Manufacturer -notmatch 'QEMU|Bochs' -and $machine.Model -notmatch 'QEMU|Standard PC') { throw 'Refusing installation outside the disposable QEMU guest.' }
    if (-not [Environment]::UserInteractive -or -not [Environment]::Is64BitProcess) { throw 'Interactive native x64 Windows PowerShell is required.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The fresh guest local administrator session is required.' }
    $installDirectory=Join-Path $env:LOCALAPPDATA 'Programs\ScreenTrail'
    $registration='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenTrail'
    if ((Test-Path -LiteralPath $installDirectory) -or (Test-Path -LiteralPath $registration) -or (Get-Process -Name ScreenTrail -ErrorAction SilentlyContinue)) { throw 'Refusing to alter an existing ScreenTrail installation or process.' }
    if ($record.dotnetDirectoriesBefore.Count -ne 0 -or $record.vcBefore.present) { Add-Note 'A runtime was already present in the guest; inspect environment evidence before calling this a pristine prerequisite test.' }

    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
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
    public class Window { public int ProcessId; public long Handle; public string Title; public string ClassName; public bool Visible; public bool Minimized; public Rect Bounds; }
    public static Window[] Read(int pid) {
        var list=new List<Window>();
        EnumWindows((h,l)=> { uint p; GetWindowThreadProcessId(h,out p); if(p!=pid) return true;
            var title=new StringBuilder(2048); var cls=new StringBuilder(256); GetWindowText(h,title,title.Capacity); GetClassName(h,cls,cls.Capacity);
            Rect r; GetWindowRect(h,out r); list.Add(new Window { ProcessId=pid,Handle=h.ToInt64(),Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(h),Minimized=IsIconic(h),Bounds=r }); return true;
        },IntPtr.Zero); return list.ToArray();
    }
}
'@
    $record.stage='verify-compatibility-prerelease-installer'
    $file=Get-Item -LiteralPath $InstallerPath
    $hash=(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $record.installer=@{ path=$file.FullName; bytes=$file.Length; sha256=$hash }
    if ($file.Length -ne 894021291 -or $hash -cne 'e00b82b8077786483b1c3e7caa4d61dc35cf16f4c418c57a5af0ff06aecad0e8') { throw 'Installer does not match the pinned compatibility prerelease 0.1.16 artifact.' }
    $record.stage='install'
    $installStarted=Get-Date
    $installer=Start-Process -FilePath $file.FullName -ArgumentList '/S' -PassThru
    $null=$installer.Handle # Cache the native handle before process completion on Windows PowerShell 5.1.
    $record.installer.processId=$installer.Id
    $attempt=0
    while (-not $installer.HasExited -and ((Get-Date)-$installStarted).TotalSeconds -lt 720) {
        Start-Sleep -Seconds 4
        $installer.Refresh()
        if ($installer.HasExited) { break }
        # Do not compete with payload extraction by compiling helpers before VC starts.
        if (-not (Get-Process -Name 'VC_redist.x64' -ErrorAction SilentlyContinue)) { continue }
        $attempt++
        $vcResult=Join-Path $ResultsDirectory ('prerequisite-ui-{0:d3}.json' -f $attempt)
        $completed=Invoke-Helper $vcHelper ('-InstallerId '+$installer.Id+' -ResultPath "'+$vcResult+'"') 15
        if (Test-Path -LiteralPath $vcResult) {
            $actions=@(Get-Content -LiteralPath $vcResult -Raw | ConvertFrom-Json)
            if ($actions.Count -gt 0) { $record.prerequisiteActions += $actions }
            else { Remove-Item -LiteralPath $vcResult -Force }
        }
        if (-not $completed) { Add-Note 'One prerequisite UI helper exceeded its bounded wait or failed.' }
        $installer.Refresh()
    }
    $record.installer.elapsedSeconds=[Math]::Round(((Get-Date)-$installStarted).TotalSeconds,2)
    $record.installer.timedOut=-not $installer.HasExited
    Save-InstallerState
    if (-not $installer.HasExited) { throw 'compatibility prerelease installer did not finish within twelve minutes; process/window evidence was preserved.' }
    $record.installer.exitCode=$installer.ExitCode
    $record.vcAfter=Get-VcState
    if ($installer.ExitCode -ne 0) { throw ('compatibility prerelease installer failed with exit code '+$installer.ExitCode) }
    $record.stage='verify-installation'
    $registered=Get-ItemProperty -LiteralPath $registration
    $record.registration=@{ version=$registered.DisplayVersion; location=$registered.InstallLocation }
    $installDirectory=$registered.InstallLocation
    $executable=Join-Path $installDirectory 'ScreenTrail.exe'
    $marker=[IO.File]::ReadAllText((Join-Path $installDirectory '.screentrail-install')).Trim()
    $record.installed=@{ marker=$marker; fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion; executable=$executable; shortcutExists=(Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'ScreenTrail.lnk')) }
    if ($registered.DisplayVersion -cne '0.1.16' -or $marker -cne 'ScreenTrail 0.1.16' -or $record.installed.fileVersion -notmatch '^0\.1\.16\.0(?:\s|\+|$)') { throw 'Installed version or marker does not match 0.1.16.' }
    $reportPath=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs\install-latest.json'
    $installReport=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($installReport.status -ne 'completed' -or -not $installReport.committed) { throw 'Authoritative installation report did not commit successfully.' }
    $record.installationPassed=$true
    $identityFiles=@('ScreenTrail.exe','ScreenTrail.dll','ScreenTrail.runtimeconfig.json','ScreenTrail.deps.json','hostfxr.dll','hostpolicy.dll','coreclr.dll','PresentationNative_cor3.dll','wpfgfx_cor3.dll','package-manifest.json')
    Write-Json 'installed-file-hashes.json' @($identityFiles | ForEach-Object { $item=Get-Item -LiteralPath (Join-Path $installDirectory $_); @{ name=$item.Name; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); version=$item.VersionInfo.FileVersion } })

    $record.stage='launch-compatibility-prerelease-app'
    $candidate=Test-AppVariant $executable 'candidate'
    $record.candidate=$candidate
    $record.startupPassed=$candidate.passed
    $record.passed=$candidate.passed
    $record.stage='completed'
    if (-not $record.passed) { $record.failure='compatibility prerelease startup failed; see candidate evidence.' }

} catch {
    $record.failure=$_.Exception.Message
    $record.failureType=$_.Exception.GetType().FullName
    $record.failureLine=$_.InvocationInfo.ScriptLineNumber
} finally {
    try { $record.vcAfter=Get-VcState } catch { Add-Note ('VC poststate: '+$_.Exception.Message) }
    try {
        $events=@(Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$started } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -in @('.NET Runtime','Application Error','Windows Error Reporting','SideBySide') } | Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message)
        Write-Json 'startup-events.json' $events
        $record.cetRuntimeFailureObserved=@($events | Where-Object { $_.Message -match '(?i)80131506|CET|shadow.stack' }).Count -gt 0
    } catch { Add-Note ('Event collection: '+$_.Exception.Message) }
    try {
        $logs=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs'
        if (Test-Path -LiteralPath $logs) { Get-ChildItem -LiteralPath $logs -File | Where-Object { $_.Length -le 10MB } | Copy-Item -Destination $ResultsDirectory -Force }
        $tempLogs=@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'dd_vcredist*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $started -and $_.Length -le 10MB })
        foreach ($log in $tempLogs) { Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $ResultsDirectory $log.Name) -Force }
    } catch { Add-Note ('Log collection: '+$_.Exception.Message) }
    if ($null -ne $installer) { $installer.Dispose() }
    $record.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Write-Json 'result.json' $record
}
if ($record.passed) { Write-Host 'PASS: exact compatibility prerelease 0.1.16 installed and displayed its responsive dashboard on Windows 10.'; exit 0 }
Write-Host ('FAIL at '+$record.stage+': '+$record.failure)
exit 1
