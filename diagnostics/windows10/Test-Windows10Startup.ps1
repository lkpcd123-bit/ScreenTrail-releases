[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory,
    [string]$CandidateUrl,
    [string]$CandidateSha256='dd1e5069f491e230f35ca314784bd75dfffc791c1635d25011730c6137e6b713'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
$started = Get-Date
$record = [ordered]@{ schemaVersion=1; startedUtc=$started.ToUniversalTime().ToString('o'); passed=$false; stage='environment'; installationPassed=$false; startupPassed=$false; samples=@(); notes=@(); prerequisiteActions=@() }
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
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
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
        $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$candidate.ProcessId)
        $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,$condition)
        foreach($window in $windows) {
            $title=$window.Current.Name
            if($title -notmatch 'Microsoft Visual C\+\+.*Redistributable' -or $window.Current.IsOffscreen) { continue }
            $controls=$window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
            $actions += @{ processId=$candidate.ProcessId; title=$title; action='observed'; controls=@($controls | ForEach-Object { @{ name=$_.Current.Name; type=$_.Current.ControlType.ProgrammaticName; enabled=$_.Current.IsEnabled } }) }
            foreach($control in $controls) {
                if($control.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and $control.Current.Name -match 'agree.*license terms' -and $control.Current.IsEnabled) {
                    $toggle=$control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                    if($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::Off) { $toggle.Toggle(); $actions += @{ action='accept-bundled-microsoft-vc-license'; processId=$candidate.ProcessId } }
                }
            }
            foreach($control in $controls) {
                $name=$control.Current.Name -replace '&',''
                if($control.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $name -eq 'Install' -and $control.Current.IsEnabled) {
                    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $actions += @{ action='install-bundled-microsoft-vc-runtime'; processId=$candidate.ProcessId }; break
                }
                if($control.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $name -eq 'Close' -and $control.Current.IsEnabled) {
                    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $actions += @{ action='close-bundled-microsoft-vc-result'; processId=$candidate.ProcessId }; break
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
        $controls=@($children | ForEach-Object { @{ name=$_.Current.Name; type=$_.Current.ControlType.ProgrammaticName; enabled=$_.Current.IsEnabled; offscreen=$_.Current.IsOffscreen } })
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
        # The baseline must release its mutex before the candidate is started.
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
    $record.stage='verify-published-installer'
    $file=Get-Item -LiteralPath $InstallerPath
    $hash=(Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $record.installer=@{ path=$file.FullName; bytes=$file.Length; sha256=$hash }
    if ($file.Length -ne 894056049 -or $hash -cne '36e9b34c7bdec0739fb52de6aeeee57e1c212ac37f20b1b5a3fd7832b507e77e') { throw 'Installer does not match the published 0.1.15 artifact.' }
    $record.stage='install'
    $installStarted=Get-Date
    $installer=Start-Process -FilePath $file.FullName -ArgumentList '/S' -PassThru
    $record.installer.processId=$installer.Id
    $attempt=0
    while (-not $installer.HasExited -and ((Get-Date)-$installStarted).TotalSeconds -lt 480) {
        Start-Sleep -Seconds 4
        $installer.Refresh()
        if ($installer.HasExited) { break }
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
    if (-not $installer.HasExited) { throw 'Published installer did not finish within eight minutes; process/window evidence was preserved.' }
    $record.installer.exitCode=$installer.ExitCode
    $record.vcAfter=Get-VcState
    if ($installer.ExitCode -ne 0) { throw ('Published installer failed with exit code '+$installer.ExitCode) }
    $record.stage='verify-installation'
    $registered=Get-ItemProperty -LiteralPath $registration
    $record.registration=@{ version=$registered.DisplayVersion; location=$registered.InstallLocation }
    $installDirectory=$registered.InstallLocation
    $executable=Join-Path $installDirectory 'ScreenTrail.exe'
    $marker=[IO.File]::ReadAllText((Join-Path $installDirectory '.screentrail-install')).Trim()
    $record.installed=@{ marker=$marker; fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion; executable=$executable; shortcutExists=(Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'ScreenTrail.lnk')) }
    if ($registered.DisplayVersion -cne '0.1.15' -or $marker -cne 'ScreenTrail 0.1.15' -or $record.installed.fileVersion -notmatch '^0\.1\.15\.0(?:\s|\+|$)') { throw 'Installed version or marker does not match 0.1.15.' }
    $reportPath=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs\install-latest.json'
    $installReport=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($installReport.status -ne 'completed' -or -not $installReport.committed) { throw 'Authoritative installation report did not commit successfully.' }
    $record.installationPassed=$true
    $identityFiles=@('ScreenTrail.exe','ScreenTrail.dll','ScreenTrail.runtimeconfig.json','ScreenTrail.deps.json','hostfxr.dll','hostpolicy.dll','coreclr.dll','PresentationNative_cor3.dll','wpfgfx_cor3.dll','package-manifest.json')
    Write-Json 'installed-file-hashes.json' @($identityFiles | ForEach-Object { $item=Get-Item -LiteralPath (Join-Path $installDirectory $_); @{ name=$item.Name; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); version=$item.VersionInfo.FileVersion } })

    $record.stage='launch-published-app'
    $baseline=Test-AppVariant $executable 'baseline'
    $record.baseline=$baseline
    $record.startupPassed=$baseline.passed
    if ($baseline.Contains('cleanupFailed') -and $baseline.cleanupFailed) { throw 'Baseline cleanup failed; refusing a competing candidate launch.' }
    if ($CandidateUrl) {
        $record.stage='verify-candidate'
        $candidatePath=Join-Path $installDirectory 'ScreenTrail.CetDiagnostic.exe'
        if (Test-Path -LiteralPath $candidatePath) { throw 'Refusing to replace an existing diagnostic executable.' }
        Invoke-WebRequest -UseBasicParsing -Uri $CandidateUrl -OutFile $candidatePath -TimeoutSec 60
        $candidateHash=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($candidateHash -cne $CandidateSha256.ToLowerInvariant()) { throw 'Candidate hash did not match its pinned identity.' }
        $originalBytes=[IO.File]::ReadAllBytes($executable)
        $candidateBytes=[IO.File]::ReadAllBytes($candidatePath)
        if ($originalBytes.Length -ne $candidateBytes.Length) { throw 'Candidate length differs from the original apphost.' }
        $differences=@(for($index=0;$index -lt $originalBytes.Length;$index++) { if($originalBytes[$index] -ne $candidateBytes[$index]) { $index } })
        $record.candidateIdentity=@{ sha256=$candidateHash; bytes=$candidateBytes.Length; changedOffsets=$differences; originalSha256=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() }
        if ($differences.Count -ne 1 -or $differences[0] -ne 0x21ac0 -or $originalBytes[0x21ac0] -ne 1 -or $candidateBytes[0x21ac0] -ne 0) { throw 'Candidate is not the expected isolated one-byte CET compatibility change.' }
        $record.stage='launch-cet-candidate'
        $candidate=Test-AppVariant $candidatePath 'candidate'
        $record.candidate=$candidate
        $record.cetHypothesisReproduced=(-not $baseline.passed -and $candidate.passed)
        $record.cetFailureSignatureWithCandidateRecovery=($record.cetHypothesisReproduced -and $baseline.cetRuntimeFailureObserved)
    }
    $record.passed=$baseline.passed -and (-not $CandidateUrl -or $record.candidate.passed)
    $record.stage='completed'
    if (-not $record.passed) { $record.failure='Published baseline or optional diagnostic candidate failed; see per-variant evidence.' }

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
if ($record.passed) { Write-Host 'PASS: exact published 0.1.15 installed and displayed its responsive dashboard on Windows 10.'; exit 0 }
Write-Host ('FAIL at '+$record.stage+': '+$record.failure)
exit 1
