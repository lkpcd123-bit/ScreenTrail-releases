[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') { throw 'Disposable GitHub-hosted Windows runner only.' }
$output=Join-Path $env:GITHUB_WORKSPACE 'artifacts\startup-probe'
$null=New-Item -ItemType Directory -Path $output -Force
$result=[ordered]@{ passed=$false; scope='Execute the exact local diagnostic bundle against published 0.1.16 on Windows Server; not affected-PC or Windows 10 proof.'; startedUtc=[DateTime]::UtcNow.ToString('o') }
$desktop=[Environment]::GetFolderPath('DesktopDirectory')
$createdZips=@()
try {
    $archive=Join-Path $PSScriptRoot 'ScreenTrail-Windows10-Startup-Diagnostic.zip'
    $result.bundleSha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if($result.bundleSha256 -cne 'bb200bbbbc6e0adddd23b452fdbdbab921ad5722f44e3ce41d9c3f1ec6684fc6') { throw 'The local probe ZIP changed from its reviewed bytes.' }
    $tools=Join-Path $env:RUNNER_TEMP 'ScreenTrail-startup-probe'
    Expand-Archive -LiteralPath $archive -DestinationPath $tools
    $entries=@(Get-ChildItem -LiteralPath $tools -File | ForEach-Object Name | Sort-Object)
    if(($entries -join '|') -cne 'Collect-ScreenTrailStartup.ps1|README.txt|Start-Diagnostic.cmd') { throw 'Unexpected probe bundle contents.' }
    $script=Join-Path $tools 'Collect-ScreenTrailStartup.ps1'
    $bytes=[IO.File]::ReadAllBytes($script)
    if($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'PowerShell 5.1 Korean source requires UTF-8 BOM.' }
    $destination=Join-Path $env:LOCALAPPDATA 'Programs\ScreenTrail'
    $executable=Join-Path $destination 'ScreenTrail.exe'
    $expectedAppHash='850dccff0e5db212747428829bff61fcc3d3f71b0354c8ae33a19e25ed5cf25d'
    if((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedAppHash) { throw 'Installed executable is not the pinned 0.1.16 apphost.' }
    if(Get-Process -Name ScreenTrail -ErrorAction SilentlyContinue) { throw 'Prior startup test did not clean up its own application.' }
    $before=@(Get-ChildItem -LiteralPath $desktop -Filter 'ScreenTrail-*.zip' -File | ForEach-Object FullName)
    # Synthetic strings exercise the log filter without any real private data.
    $sentinel='PROBE_PRIVATE_TEXT_'+[Guid]::NewGuid().ToString('N')
    $logs=Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs'
    $null=New-Item -ItemType Directory -Path $logs -Force
    [IO.File]::WriteAllLines((Join-Path $logs 'app.log'),@($sentinel,([DateTime]::UtcNow.ToString('o')+' ScreenTrail.ProbeSyntheticException HResult=80004005'),'   at ScreenTrail.ProbeSyntheticError()'),[Text.UTF8Encoding]::new($false))
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $PSHOME 'powershell.exe'
    $start.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$script+'"'
    $start.UseShellExecute=$false
    $probe=[Diagnostics.Process]::Start($start)
    $null=$probe.Handle
    try {
        if(-not $probe.WaitForExit(90000)) { $probe.Kill(); throw 'Diagnostic process exceeded ninety seconds.' }
        $result.probeExitCode=$probe.ExitCode
        if($probe.ExitCode -ne 0) { throw ('Diagnostic process failed: '+$probe.ExitCode) }
    } finally { $probe.Dispose() }
    $createdZips=@(Get-ChildItem -LiteralPath $desktop -Filter 'ScreenTrail-*.zip' -File | Where-Object { $_.FullName -notin $before })
    if($createdZips.Count -ne 1) { throw 'Expected exactly one new desktop result ZIP.' }
    $result.reportZip=$createdZips[0].Name
    $reports=Join-Path $output 'report'
    Expand-Archive -LiteralPath $createdZips[0].FullName -DestinationPath $reports
    $report=Get-Content -LiteralPath (Join-Path $reports 'result.json') -Raw | ConvertFrom-Json
    $os=Get-CimInstance Win32_OperatingSystem
    if(-not $report.diagnosticCompleted -or -not $report.applicationStarted -or $report.existingProcesses.Count -ne 0) { throw 'Probe did not perform a clean original-app launch.' }
    if($report.os.build -cne $os.BuildNumber -or $report.os.caption -cne $os.Caption -or -not $report.is64BitProcess) { throw 'Probe reported the wrong OS or process architecture.' }
    if($report.application.version -cne '0.1.16.0' -or $report.application.sha256 -cne $expectedAppHash -or $report.application.bytes -ne 187392) { throw 'Probe reported the wrong application identity.' }
    if($report.samples.Count -ne 2 -or $report.samples[0].elapsedSeconds -lt 3 -or $report.samples[1].elapsedSeconds -lt 10 -or @($report.samples | Where-Object exited).Count -gt 0) { throw 'Expected alive process samples at three and ten seconds.' }
    $visible=@($report.samples[1].windows | Where-Object { $_.Visible -and $_.Title -ceq 'ScreenTrail' })
    if($visible.Count -ne 1) { throw 'Probe did not observe the visible dashboard.' }
    $application=Get-Process -Id $report.processId
    $application.Refresh()
    if($application.HasExited -or -not $application.Responding -or $application.MainWindowHandle -eq [IntPtr]::Zero -or $application.MainWindowTitle -cne 'ScreenTrail') { throw 'Probe failed to leave the healthy application running with its main window.' }
    $result.healthyApplicationLeftRunning=$true
    $allowed=@('README.txt','result.json','application-events.json','app-error-identifiers.txt','dotnet-host-trace.log','corehost-trace.log','startup-stdout.txt','startup-stderr.txt')
    $files=@(Get-ChildItem -LiteralPath $reports -File -Recurse)
    foreach($file in $files) {
        if($file.Name -notin $allowed -or $file.DirectoryName -cne $reports) { throw ('Unexpected report content: '+$file.Name) }
        if([IO.File]::ReadAllText($file.FullName).Contains($sentinel)) { throw 'A synthetic arbitrary app-log message escaped the privacy filter.' }
    }
    $identifiers=[IO.File]::ReadAllText((Join-Path $reports 'app-error-identifiers.txt'))
    if(-not $identifiers.Contains('ScreenTrail.ProbeSyntheticException HResult=80004005') -or -not $identifiers.Contains('at ScreenTrail.ProbeSyntheticError()')) { throw 'The log filter lost structured error identifiers.' }
    if(-not (Test-Path -LiteralPath (Join-Path $reports 'dotnet-host-trace.log'))) { throw 'Per-process host tracing was not captured.' }
    if((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedAppHash) { throw 'Installed original apphost changed during the probe.' }
    $result.os=$report.os; $result.application=$report.application; $result.reportFiles=@($files | ForEach-Object Name)
    $result.samples=$report.samples; $result.privacySentinelExcluded=$true; $result.originalExecutableUnchanged=$true
    $result.actualScreenTrailHealthyCasePassed=$true

    # Separate synthetic early-exit proof: the collector must retain exit code 42.
    # Stop only the healthy process launched by this test, after proving the probe
    # left it alive. Never replace the installed executable.
    if($application.Path -ine $executable) { throw 'Refusing to stop a process outside the verified installation.' }
    $null=$application.Handle
    $application.Kill()
    if(-not $application.WaitForExit(10000)) { throw 'The test-owned healthy app did not exit before the synthetic fixture.' }
    $application.Dispose()
    $result.testOwnedAppStoppedForSyntheticFixture=$true
    $registration='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenTrail'
    $originalLocation=(Get-ItemProperty -LiteralPath $registration).InstallLocation
    try {
        $fixture=Join-Path $env:RUNNER_TEMP ('ScreenTrail-exit42-'+[Guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $fixture
        $fixtureExe=Join-Path $fixture 'ScreenTrail.exe'
        Add-Type -TypeDefinition @'
using System.Reflection;
[assembly: AssemblyFileVersion("0.0.42.0")]
public static class SyntheticScreenTrailExit42 { public static int Main() { return 42; } }
'@ -OutputAssembly $fixtureExe -OutputType WindowsApplication
        Set-ItemProperty -LiteralPath $registration -Name InstallLocation -Value $fixture
        $beforeFixture=@(Get-ChildItem -LiteralPath $desktop -Filter 'ScreenTrail-*.zip' -File | ForEach-Object FullName)
        $fixtureProbe=[Diagnostics.Process]::Start($start)
        $null=$fixtureProbe.Handle
        try {
            if(-not $fixtureProbe.WaitForExit(90000)) { $fixtureProbe.Kill(); throw 'Synthetic-case diagnostic exceeded ninety seconds.' }
            if($fixtureProbe.ExitCode -ne 0) { throw ('Synthetic-case diagnostic failed: '+$fixtureProbe.ExitCode) }
        } finally { $fixtureProbe.Dispose() }
        $fixtureZips=@(Get-ChildItem -LiteralPath $desktop -Filter 'ScreenTrail-*.zip' -File | Where-Object { $_.FullName -notin $beforeFixture })
        $createdZips += $fixtureZips
        if($fixtureZips.Count -ne 1) { throw 'Synthetic early exit did not produce exactly one report ZIP.' }
        $fixtureReports=Join-Path $output 'synthetic-exit42-report'
        Expand-Archive -LiteralPath $fixtureZips[0].FullName -DestinationPath $fixtureReports
        $earlyExit=Get-Content -LiteralPath (Join-Path $fixtureReports 'result.json') -Raw | ConvertFrom-Json
        if(-not $earlyExit.diagnosticCompleted -or -not $earlyExit.applicationStarted -or $earlyExit.samples.Count -ne 2) { throw 'Synthetic early-exit diagnostic did not complete its samples.' }
        foreach($sample in $earlyExit.samples) {
            if(-not $sample.exited -or $sample.exitCode -ne 42 -or $sample.exitCodeHex -cne '0x0000002A') { throw 'Synthetic early-exit code 42 was lost or incorrectly reported.' }
        }
        if($earlyExit.application.path -ine $fixtureExe -or $earlyExit.application.sha256 -cne (Get-FileHash -LiteralPath $fixtureExe -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Synthetic fixture identity was not recorded correctly.' }
        $result.syntheticEarlyExit=@{ passed=$true; source='Test-only .NET Framework executable returning 42, not ScreenTrail failure reproduction.'; reportZip=$fixtureZips[0].Name; samples=$earlyExit.samples }
    } finally { Set-ItemProperty -LiteralPath $registration -Name InstallLocation -Value $originalLocation }
    if((Get-ItemProperty -LiteralPath $registration).InstallLocation -cne $originalLocation -or (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedAppHash) { throw 'Original installation identity was not preserved after the synthetic case.' }
    $result.originalRegistrationRestored=$true
    $result.passed=$true
} catch { $result.failure=$_.Exception.Message; throw }
finally {
    # Preserve the diagnostic's own exception details even if it could not zip.
    $folders=@(Get-ChildItem -LiteralPath $desktop -Directory -Filter 'ScreenTrail-*' -ErrorAction SilentlyContinue)
    foreach($folder in $folders) {
        $metadata=Join-Path $folder.FullName 'result.json'
        if(Test-Path -LiteralPath $metadata) { Copy-Item -LiteralPath $metadata -Destination (Join-Path $output ($folder.Name+'-result.json')) -Force }
    }
    foreach($zip in $createdZips) { Copy-Item -LiteralPath $zip.FullName -Destination $output -Force }
    $result.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'probe-verification.json') -Encoding UTF8
}
