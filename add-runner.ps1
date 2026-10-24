# Adds a self-hosted GitHub Actions runner for any repository, as a Windows service.
# Double-click "Add GitHub runner.cmd": Windows asks for admin rights once, then this asks which repository.
# Runners live in C:\actions-runner\runnerN; each one serves one repository.
param([string]$repo = '', [string]$name = '')
$ErrorActionPreference = 'Stop'
$root = 'C:\actions-runner'
$zip = Get-ChildItem "$env:USERPROFILE\actions-runner\actions-runner-win-*.zip", "$root\*.zip" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }

function Show-Runners {
    Write-Host "Runners on this computer:" -ForegroundColor Cyan
    Get-ChildItem $root -Directory -Filter 'runner*' | ForEach-Object {
        $file = Join-Path $_.FullName '.runner'
        if (Test-Path $file) {
            $info = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $svc = Get-Service -Name "actions.runner.*.$($info.agentName)" -ErrorAction SilentlyContinue
            $state = if ($svc) { $svc.Status } else { 'no service' }
            '  {0,-9} {1,-28} {2,-45} {3}' -f $_.Name, $info.agentName, $info.gitHubUrl, $state
        } else {
            '  {0,-9} (not registered)' -f $_.Name
        }
    }
}

try {
    Show-Runners
    if (-not $repo) { $repo = Read-Host "`nWhich repository? (owner/name, e.g. awakekt/awake-studio)" }
    $repo = $repo.Trim()
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "'$repo' isn't owner/name." }

    Step "Checking GitHub sign-in and access to $repo"
    gh auth status | Out-Null
    gh repo view $repo --json name | Out-Null

    # Reuse a folder already registered to this repository but missing its service; otherwise take the next free runnerN.
    $dir = $null
    foreach ($folder in Get-ChildItem $root -Directory -Filter 'runner*') {
        $file = Join-Path $folder.FullName '.runner'
        if ((Test-Path $file) -and ((Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json).gitHubUrl -eq "https://github.com/$repo")) {
            $agent = (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json).agentName
            if (-not (Get-Service -Name "actions.runner.*.$agent" -ErrorAction SilentlyContinue)) { $dir = $folder.FullName; break }
        }
    }
    if (-not $dir) {
        $n = 1; while (Test-Path "$root\runner$n") { $n++ }
        $dir = "$root\runner$n"
    }
    if (-not $name) {
        $base = ($repo -split '/')[1] + '-runner'
        $taken = @(gh api "repos/$repo/actions/runners" --jq '.runners[].name')
        $name = $base; $i = 2
        while ($taken -contains $name) { $name = "$base-$i"; $i++ }
    }
    Write-Host "Folder: $dir    Name: $name"

    if (-not (Test-Path "$dir\config.cmd")) {
        if (-not $zip) { throw "No runner zip found in $env:USERPROFILE\actions-runner or $root. Download one from GitHub's runner page first." }
        Step "Unpacking the runner into $dir"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Expand-Archive $zip.FullName -DestinationPath $dir -Force
    }
    Set-Location $dir

    if (Test-Path "$dir\.runner") {
        Step "Removing the half-finished registration"
        $remove = gh api -X POST "repos/$repo/actions/runners/remove-token" --jq .token
        & .\config.cmd remove --token $remove
    }

    Step "Registering $name for $repo and installing its service"
    $token = gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
    & .\config.cmd --url "https://github.com/$repo" --token $token --name $name `
        --labels 'self-hosted,Windows,X64' --work _work --runasservice `
        --windowslogonaccount 'NT AUTHORITY\NETWORK SERVICE' --unattended --replace
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed (exit $LASTEXITCODE)." }

    Write-Host ""
    Show-Runners
    Write-Host "`nDone. Jobs that ask for 'runs-on: self-hosted' (or [self-hosted, Windows]) in $repo now run here." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Copy this window's text to Claude." -ForegroundColor Yellow
}
Read-Host "`nPress Enter to close"
