[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$AssetId)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Run only on a disposable GitHub-hosted Windows runner.'
}
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows Server' -or -not [Environment]::Is64BitProcess) { throw 'An x64 Windows Server runner is required.' }
$destination = Join-Path $env:LOCALAPPDATA 'Programs\ScreenTrail'
$registrationPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenTrail'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $registrationPath) -or (Get-Process ScreenTrail -ErrorAction SilentlyContinue)) {
    throw 'Refusing to touch a pre-existing installation or process.'
}
$output = Join-Path $env:GITHUB_WORKSPACE 'artifacts\candidate-startup'
$null = New-Item -ItemType Directory -Path $output -Force
$installer = Join-Path $env:RUNNER_TEMP 'ScreenTrail-0.1.16-Setup.exe'
$expectedHash = 'e00b82b8077786483b1c3e7caa4d61dc35cf16f4c418c57a5af0ff06aecad0e8'
$report = [ordered]@{
    version = '0.1.16'; completed = $false; startedUtc = [DateTime]::UtcNow.ToString('o')
    os = $os.Caption; build = $os.BuildNumber; powershell = $PSVersionTable.PSVersion.ToString()
    scope = 'Exact DRAFT candidate EXE clean silent installation and real desktop startup on Windows Server. No licensing, Windows 10 desktop, upgrade or capture feature tests.'
    stage = 'download'; destination = $destination; releaseState = 'DRAFT candidate'; assetId = $AssetId
}
try {
    $runtime = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if (-not $runtime -or $runtime.Installed -ne 1) { throw 'The hosted runner needs its standard Visual C++ runtime for this unattended smoke test.' }
    $report.visualCppRuntimeBefore = $runtime.Version
    & curl.exe --fail --location --retry 2 --silent --show-error --max-time 240 --header "Authorization: Bearer $env:GH_TOKEN" --header 'Accept: application/octet-stream' --output $installer ("https://api.github.com/repos/ikk5515/ScreenTrail-releases/releases/assets/" + $AssetId)
    if ($LASTEXITCODE -ne 0) { throw "Installer download failed: $LASTEXITCODE" }
    $report.stage = 'verify-download'
    $report.installerBytes = (Get-Item -LiteralPath $installer).Length
    $report.installerSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.installerBytes -ne 894021291 -or $report.installerSha256 -cne $expectedHash) { throw 'The downloaded installer does not match the pinned DRAFT candidate bytes.' }
    $report.stage = 'install'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $installerProcess = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
    try {
        if (-not $installerProcess.WaitForExit(360000)) {
            $installerProcess.Kill()
            throw 'Installer exceeded the six-minute timeout.'
        }
        $installerProcess.Refresh()
        $report.installerExitCode = $installerProcess.ExitCode
        $report.installSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
        if ($installerProcess.ExitCode -ne 0) { throw "Installer failed: $($installerProcess.ExitCode)" }
    } finally { $installerProcess.Dispose() }
    $report.stage = 'verify-installation'
    $registration = Get-ItemProperty -LiteralPath $registrationPath
    if ($registration.DisplayVersion -cne '0.1.16' -or $registration.InstallLocation.TrimEnd('\') -ine $destination.TrimEnd('\')) { throw 'Installed app registration is incorrect.' }
    $report.registeredVersion = $registration.DisplayVersion
    foreach ($name in @('ScreenTrail.exe','ScreenTrail.dll','ScreenTrail.Uninstall.exe','package-manifest.json','.screentrail-install')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $name) -PathType Leaf)) { throw "Missing installed file: $name" }
    }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $destination 'ScreenTrail.exe')).FileVersion
    if (([version]$fileVersion).ToString(3) -cne '0.1.16') { throw 'Installed executable has the wrong version.' }
    $report.executableVersion = $fileVersion
    if ([IO.File]::ReadAllText((Join-Path $destination '.screentrail-install')).Trim() -cne 'ScreenTrail 0.1.16') { throw 'Installation marker is incorrect.' }
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'ScreenTrail.lnk'
    if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { throw 'Start menu shortcut is missing.' }
    $report.startMenuShortcut = $true
    $logs = Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs'
    $terminal = Get-Content -LiteralPath (Join-Path $logs 'install-latest.json') -Raw | ConvertFrom-Json
    if ($terminal.status -cne 'completed' -or $terminal.stage -cne 'completed' -or -not $terminal.committed) { throw 'Installation report does not confirm completion.' }
    $report.auxiliaryInstallerLogComplete = ((Get-Content -LiteralPath (Join-Path $logs 'installer-latest.log') -Tail 1) -ceq 'result=completed')
    if (-not $report.auxiliaryInstallerLogComplete) { Write-Warning 'Known auxiliary installer text log is incomplete; the authoritative committed installation report passed. Continue to collect startup evidence.' }
    $report.installReportCompleted = $true
    $report.stage = 'launch'
    & (Join-Path $PSScriptRoot 'Test-PublishedStartup.ps1') -Executable (Join-Path $destination 'ScreenTrail.exe') -OutputDirectory $output
    $report.startupPassed = $true
    $report.stage = 'completed'
    $report.completed = $true
    Write-Host "PASS: DRAFT candidate ScreenTrail $($report.registeredVersion) installed on $($report.os), exit $($report.installerExitCode), $($report.installSeconds) seconds."
} catch {
    $report.failure = $_.Exception.Message
    throw
} finally {
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
    $logs = Join-Path $env:LOCALAPPDATA 'ScreenTrail\Logs'
    foreach ($name in @('install-latest.json','installer-latest.log')) {
        $path = Join-Path $logs $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination $output }
    }
}
