[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$AssetId,
    [Parameter(Mandatory=$true)][ValidatePattern('\A[a-fA-F0-9]{64}\z')][string]$Sha256,
    [Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$Bytes,
    [Parameter(Mandatory=$true)][ValidatePattern('\A(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})\z')][string]$Version,
    [Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$HarnessAssetId,
    [Parameter(Mandatory=$true)][ValidatePattern('\A[a-fA-F0-9]{64}\z')][string]$HarnessSha256,
    [Parameter(Mandatory=$true)][ValidateRange(1,[long]::MaxValue)][long]$HarnessBytes
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$parsedVersion=[version]$Version
if (@($parsedVersion.Major,$parsedVersion.Minor,$parsedVersion.Build | Where-Object { $_ -gt 65535 }).Count -gt 0) { throw 'Version components must fit Windows file version fields (0-65535).' }
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
$output = Join-Path $env:GITHUB_WORKSPACE 'artifacts\clipboard-release-install'
$null = New-Item -ItemType Directory -Path $output -Force
$installer = Join-Path $env:RUNNER_TEMP ('ScreenTrail-'+$Version+'-Setup.exe')
$expectedHash = $Sha256.ToLowerInvariant()
$report = [ordered]@{
    version = $Version; completed = $false; startedUtc = [DateTime]::UtcNow.ToString('o')
    os = $os.Caption; build = $os.BuildNumber; powershell = $PSVersionTable.PSVersion.ToString()
    scope = 'Exact pinned candidate EXE clean silent installation, real desktop startup, and seven synthetic clipboard paths against its installed payload on Windows Server. No Windows 10 desktop, upgrade or physical target-app tests.'
    stage = 'download'; destination = $destination; releaseState = 'Pinned candidate; publication status not asserted'; assetId = $AssetId; expectedInstallerBytes = $Bytes; expectedInstallerSha256 = $expectedHash
}
try {
    $runtime = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if (-not $runtime -or $runtime.Installed -ne 1) { throw 'The hosted runner needs its standard Visual C++ runtime for this unattended smoke test.' }
    $report.visualCppRuntimeBefore = $runtime.Version
    & curl.exe --fail-with-body --location --retry 2 --silent --show-error --max-time 240 --header "Authorization: Bearer $env:GH_TOKEN" --header 'Accept: application/octet-stream' --output $installer ("https://api.github.com/repos/ikk5515/ScreenTrail-releases/releases/assets/" + $AssetId)
    $downloadExitCode = $LASTEXITCODE
    if ($downloadExitCode -ne 0) {
        $report.downloadExitCode = $downloadExitCode
        # Retain only GitHub's bounded JSON message, never request headers or signed URLs.
        if ((Test-Path -LiteralPath $installer -PathType Leaf) -and (Get-Item -LiteralPath $installer).Length -le 65536) {
            try {
                $downloadError = Get-Content -LiteralPath $installer -Raw | ConvertFrom-Json
                if ($downloadError.message -is [string]) { $report.downloadErrorMessage = $downloadError.message.Substring(0,[Math]::Min(2048,$downloadError.message.Length)); Write-Warning $report.downloadErrorMessage }
            } catch { }
        }
        throw "Installer download failed: $downloadExitCode"
    }
    $report.stage = 'verify-download'
    $report.installerBytes = (Get-Item -LiteralPath $installer).Length
    $report.installerSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.installerBytes -ne $Bytes -or $report.installerSha256 -cne $expectedHash) { throw 'The downloaded installer does not match the pinned candidate bytes.' }
    $report.stage = 'install'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $installerProcess = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
    $null = $installerProcess.Handle # Preserve the native handle for a reliable Windows PowerShell 5.1 ExitCode.
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
    if ($registration.DisplayVersion -cne $Version -or $registration.InstallLocation.TrimEnd('\') -ine $destination.TrimEnd('\')) { throw 'Installed app registration is incorrect.' }
    $report.registeredVersion = $registration.DisplayVersion
    foreach ($name in @('ScreenTrail.exe','ScreenTrail.dll','ScreenTrail.Uninstall.exe','package-manifest.json','.screentrail-install')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $name) -PathType Leaf)) { throw "Missing installed file: $name" }
    }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $destination 'ScreenTrail.exe')).FileVersion
    if (([version]$fileVersion).ToString(3) -cne $Version) { throw 'Installed executable has the wrong version.' }
    $report.executableVersion = $fileVersion
    if ([IO.File]::ReadAllText((Join-Path $destination '.screentrail-install')).Trim() -cne ('ScreenTrail '+$Version)) { throw 'Installation marker is incorrect.' }
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
    $report.stage = 'clipboard'
    $clipboardOutput = Join-Path $env:GITHUB_WORKSPACE 'artifacts\installed-clipboard'
    $null = New-Item -ItemType Directory -Path $clipboardOutput -Force
    $harnessZip = Join-Path $env:RUNNER_TEMP 'ScreenTrail.ClipboardChecks.zip'
    $testOutput = Join-Path $env:RUNNER_TEMP ('installed-clipboard-' + [Guid]::NewGuid().ToString('N'))
    $installedDll = Join-Path $destination 'ScreenTrail.dll'
    $installedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installedDll).FileVersion
    if (([version]$installedVersion).ToString(3) -cne $Version) { throw 'Installed product assembly version differs from the pinned candidate.' }
    $proof = [ordered]@{
        installedAssembly = $installedDll; installedVersion = $installedVersion
        installedBytes = (Get-Item -LiteralPath $installedDll).Length
        installedSha256 = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash.ToLowerInvariant()
        harnessAssetId = $HarnessAssetId; expectedHarnessBytes = $HarnessBytes
        expectedHarnessSha256 = $HarnessSha256.ToLowerInvariant(); testDirectory = $testOutput
        scope = 'The complete installed payload is copied to an isolated test directory and overlaid with exactly four pinned binary harness files. No SDK, source build, or modification to the application installation is used.'
        passed = $false
    }
    try {
        & curl.exe --fail-with-body --location --retry 2 --silent --show-error --max-time 120 --header "Authorization: Bearer $env:GH_TOKEN" --header 'Accept: application/octet-stream' --output $harnessZip ("https://api.github.com/repos/ikk5515/ScreenTrail-releases/releases/assets/" + $HarnessAssetId)
        $proof.harnessDownloadExitCode = $LASTEXITCODE
        if ($proof.harnessDownloadExitCode -ne 0) {
            if ((Test-Path -LiteralPath $harnessZip -PathType Leaf) -and (Get-Item -LiteralPath $harnessZip).Length -le 65536) {
                try {
                    $downloadError = Get-Content -LiteralPath $harnessZip -Raw | ConvertFrom-Json
                    if ($downloadError.message -is [string]) { $proof.downloadErrorMessage = $downloadError.message.Substring(0,[Math]::Min(2048,$downloadError.message.Length)) }
                } catch { }
            }
            throw "Binary harness download failed: $($proof.harnessDownloadExitCode)"
        }
        $proof.harnessBytes = (Get-Item -LiteralPath $harnessZip).Length
        $proof.harnessSha256 = (Get-FileHash -LiteralPath $harnessZip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($proof.harnessBytes -ne $HarnessBytes -or $proof.harnessSha256 -cne $proof.expectedHarnessSha256) { throw 'Binary harness ZIP does not match its pinned size and SHA256.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($harnessZip)
        try {
            $expectedEntries = @('ScreenTrail.ClipboardChecks.exe','ScreenTrail.ClipboardChecks.dll','ScreenTrail.ClipboardChecks.deps.json','ScreenTrail.ClipboardChecks.runtimeconfig.json')
            $entries = @($archive.Entries)
            if ($entries.Count -ne 4 -or @($entries | ForEach-Object { $_.FullName } | Select-Object -Unique).Count -ne 4) { throw 'Binary harness ZIP must contain exactly four unique files.' }
            foreach ($entry in $entries) {
                if ($entry.FullName -cnotin $expectedEntries -or $entry.Length -le 0 -or $entry.Length -gt 16777216) { throw 'Binary harness ZIP contains an unexpected name, directory, path, or size.' }
            }
            $null = New-Item -ItemType Directory -Path $testOutput
            Get-ChildItem -LiteralPath $destination -Force | Copy-Item -Destination $testOutput -Recurse -Force
            $harnessFiles = @()
            foreach ($entry in $entries) {
                $target = Join-Path $testOutput $entry.FullName
                if (Test-Path -LiteralPath $target) { throw 'Binary harness would overwrite an installed payload file.' }
                $source = $entry.Open()
                try {
                    $sink = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                    try { $source.CopyTo($sink) } finally { $sink.Dispose() }
                } finally { $source.Dispose() }
                $harnessFiles += [ordered]@{ name = $entry.FullName; bytes = (Get-Item -LiteralPath $target).Length; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            $proof.harnessFiles = $harnessFiles
        } finally { $archive.Dispose() }
        $testDll = Join-Path $testOutput 'ScreenTrail.dll'
        $proof.testAssembly = $testDll
        $proof.testAssemblySha256 = (Get-FileHash -LiteralPath $testDll -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($proof.testAssemblySha256 -cne $proof.installedSha256) { throw 'Isolated product assembly does not match the installed release DLL.' }
        $testExe = Join-Path $testOutput 'ScreenTrail.ClipboardChecks.exe'
        & $testExe run $clipboardOutput
        $proof.testExitCode = $LASTEXITCODE
        if ($proof.testExitCode -ne 0) { throw "Installed-payload clipboard checks failed: $($proof.testExitCode)" }
        $checks = Get-Content -LiteralPath (Join-Path $clipboardOutput 'results.json') -Raw | ConvertFrom-Json
        if ($checks.passed -ne $true -or @($checks.tests).Count -ne 7 -or @($checks.tests | Where-Object { $_.passed -ne $true }).Count -ne 0) { throw 'All seven clipboard paths must pass.' }
        $proof.passed = $true
    } catch {
        $proof.failure = $_.Exception.Message
        throw
    } finally {
        $proof.installedSha256After = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash.ToLowerInvariant()
        $proof.installationUnchanged = $proof.installedSha256After -ceq $proof.installedSha256
        if ($proof.Contains('testAssembly') -and (Test-Path -LiteralPath $proof.testAssembly -PathType Leaf)) {
            $proof.testAssemblySha256After = (Get-FileHash -LiteralPath $proof.testAssembly -Algorithm SHA256).Hash.ToLowerInvariant()
            $proof.isolatedProductUnchanged = $proof.testAssemblySha256After -ceq $proof.installedSha256
        } else { $proof.isolatedProductUnchanged = $false }
        if (-not $proof.installationUnchanged -or -not $proof.isolatedProductUnchanged) { $proof.passed = $false }
        $proof | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $clipboardOutput 'installed-assembly.json') -Encoding UTF8
    }
    if (-not $proof.installationUnchanged -or -not $proof.isolatedProductUnchanged) { throw 'The installed or isolated product assembly changed during the test.' }
    $report.clipboardPassed = $true
    $report.stage = 'completed'
    $report.completed = $true
    Write-Host "PASS: pinned candidate ScreenTrail $($report.registeredVersion) installed on $($report.os), exit $($report.installerExitCode), $($report.installSeconds) seconds."
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
