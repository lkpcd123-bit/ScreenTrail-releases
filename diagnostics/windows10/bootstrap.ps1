$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$hostBase = 'http://10.0.2.2:8765'
$candidateUrl = '__CANDIDATE_URL__'
$work = 'C:\Smoke'
$results = Join-Path $work 'results'
New-Item -ItemType Directory -Path $results -Force | Out-Null
$started = [DateTime]::UtcNow
$outcome = [ordered]@{ startedUtc = $started.ToString('o'); completedUtc = $null; passed = $false; error = $null; os = $null; guestScriptExitCode = $null }
Start-Transcript -Path (Join-Path $results 'bootstrap-transcript.txt') -Force | Out-Null
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $outcome.os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; productType = $os.ProductType; architecture = $os.OSArchitecture }
    $outcome | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $results 'boot.json') -Encoding UTF8
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -ne 19045 -or $os.OSArchitecture -ne '64-bit') { throw 'Expected actual Windows 10 22H2 x64 client, build 19045.' }
    $explorerDeadline = [DateTime]::UtcNow.AddMinutes(2)
    while (!(Get-Process explorer -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $explorerDeadline) { Start-Sleep -Seconds 2 }
    if (!(Get-Process explorer -ErrorAction SilentlyContinue)) { throw 'The interactive Explorer desktop did not start.' }
    Start-Sleep -Seconds 10
    $web = New-Object System.Net.WebClient
    try {
        $web.DownloadFile("$hostBase/installer.exe", (Join-Path $work 'installer.exe'))
        $web.DownloadFile("$hostBase/Test-Windows10Startup.ps1", (Join-Path $work 'Test-Windows10Startup.ps1'))
    } finally { $web.Dispose() }
    $installer = Join-Path $work 'installer.exe'
    if ((Get-Item -LiteralPath $installer).Length -ne 894056049) { throw 'Published installer size mismatch.' }
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne '36e9b34c7bdec0739fb52de6aeeee57e1c212ac37f20b1b5a3fd7832b507e77e') { throw 'Published installer SHA256 mismatch.' }
    $scriptPath = Join-Path $work 'Test-Windows10Startup.ps1'
    $guestArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-InstallerPath', $installer, '-ResultsDirectory', $results)
    if ($candidateUrl -and $candidateUrl -ne '__CANDIDATE_URL__') { $guestArguments += @('-CandidateUrl', $candidateUrl) }
    $guest = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $guestArguments -PassThru -RedirectStandardOutput (Join-Path $results 'guest-stdout.txt') -RedirectStandardError (Join-Path $results 'guest-stderr.txt')
    if (!$guest.WaitForExit(900000)) { $guest.Kill(); throw 'The Windows 10 installer/startup test exceeded 15 minutes.' }
    $guest.WaitForExit()
    $outcome.guestScriptExitCode = $guest.ExitCode
    if ($guest.ExitCode -ne 0) { throw "The Windows 10 installer/startup test exited with code $($guest.ExitCode)." }
    if (!(Test-Path -LiteralPath (Join-Path $results 'result.json'))) { throw 'Guest test did not write result.json.' }
    $outcome.passed = $true
} catch {
    $outcome.error = $_.ToString()
    ($_ | Format-List * -Force | Out-String) | Set-Content -LiteralPath (Join-Path $results 'bootstrap-error.txt') -Encoding UTF8
} finally {
    $outcome.completedUtc = [DateTime]::UtcNow.ToString('o')
    $outcome | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $results 'bootstrap-result.json') -Encoding UTF8
    Stop-Transcript | Out-Null
    $client = New-Object System.Net.WebClient
    try {
        foreach ($file in Get-ChildItem -LiteralPath $results -File -Recurse) {
            $relative = $file.FullName.Substring($results.Length + 1).Replace('\', '/')
            $segments = $relative.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
            $urlPath = $segments -join '/'
            try { $null = $client.UploadFile("$hostBase/results/$urlPath", 'POST', $file.FullName) }
            catch { $_ | Out-String | Write-Host }
        }
        $client.Headers['Content-Type'] = 'application/json'
        $null = $client.UploadString("$hostBase/complete", 'POST', ($outcome | ConvertTo-Json -Depth 8))
    } finally { $client.Dispose() }
}
