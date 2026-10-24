# Shared helpers for the runner scripts in this folder. Imported by each script; not meant to be run directly.
# Runner installs live under $RunnerRoot (default C:\actions-runner, override with $env:RUNNER_ROOT), never in this repo.

$ErrorActionPreference = 'Stop'

$script:RunnerRoot = if ($env:RUNNER_ROOT) { $env:RUNNER_ROOT } else { 'C:\actions-runner' }
$script:InventoryPath = Join-Path $PSScriptRoot 'runners.json'
$script:ServiceAccount = 'NT AUTHORITY\NETWORK SERVICE'

# Older hand-made installs registered straight into these folders; they are scanned so strays show up in Get-Runners.
$script:LegacyFolders = @($script:RunnerRoot, (Join-Path $env:USERPROFILE 'actions-runner'))

function Get-RunnerRoot { $script:RunnerRoot }

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This needs an elevated PowerShell (Run as administrator), because it changes Windows services.'
    }
}

function Invoke-Gh {
    # Runs gh and fails loudly instead of returning an error message as if it were data.
    $out = & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed (exit $LASTEXITCODE)." }
    $out
}

function Assert-Gh {
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'gh is not signed in. Run: gh auth login' }
}

function Resolve-Repo([string]$Repo) {
    # Follows renames (awakekt/awake-pro -> awakekt/awake-studio) so API calls and comparisons use the current name.
    if ($Repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "'$Repo' isn't owner/name." }
    Invoke-Gh api "repos/$Repo" --jq .full_name
}

function ConvertTo-RepoName([string]$GitHubUrl) {
    ($GitHubUrl -replace '^https://github\.com/', '').TrimEnd('/')
}

function Get-ServiceName([string]$Repo, [string]$Name) {
    # Same scheme config.cmd uses: actions.runner.<owner>-<repo>.<runner name>
    'actions.runner.{0}.{1}' -f ($Repo -replace '/', '-'), $Name
}

function Get-LocalRunner {
    # Every folder on this computer that holds a runner registration (.runner file), with its service state.
    # .FullName, not "ForEach-Object FullName": under -WhatIf the latter is skipped and returns nothing.
    $folders = @((Get-ChildItem $script:RunnerRoot -Directory -ErrorAction SilentlyContinue).FullName) + $script:LegacyFolders
    foreach ($folder in ($folders | Select-Object -Unique)) {
        $file = Join-Path $folder '.runner'
        if (-not (Test-Path $file)) { continue }
        $info = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $repo = ConvertTo-RepoName $info.gitHubUrl
        $serviceFile = Join-Path $folder '.service'
        $serviceName = if (Test-Path $serviceFile) { (Get-Content $serviceFile -Raw).Trim() } else { Get-ServiceName $repo $info.agentName }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name          = $info.agentName
            AgentId       = [int]$info.agentId
            Repo          = $repo
            Folder        = $folder
            ServiceName   = if ($service) { $serviceName } else { $null }
            ServiceStatus = if ($service) { [string]$service.Status } else { 'no service' }
        }
    }
}

function Get-RemoteRunner([string]$Repo) {
    # Runners GitHub has registered for a repository. --paginate --jq emits one JSON object per line.
    $lines = Invoke-Gh api "repos/$Repo/actions/runners?per_page=100" --paginate --jq '.runners[] | {id, name, status, busy, labels: [.labels[].name]}'
    foreach ($line in @($lines)) { if ($line) { $line | ConvertFrom-Json } }
}

function New-RunnerToken([string]$Repo, [ValidateSet('registration', 'remove')][string]$Kind) {
    Invoke-Gh api -X POST "repos/$Repo/actions/runners/$Kind-token" --jq .token
}

function Get-RunnerPackage {
    # Latest actions/runner win-x64 zip, cached in <RunnerRoot>\_packages and checked against the SHA-256 in the release notes.
    $cache = Join-Path $script:RunnerRoot '_packages'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $release = Invoke-Gh api repos/actions/runner/releases/latest | ConvertFrom-Json
    $version = $release.tag_name.TrimStart('v')
    $zip = Join-Path $cache "actions-runner-win-x64-$version.zip"
    if (-not (Test-Path $zip)) {
        Write-Step "Downloading runner $version"
        Invoke-Gh release download $release.tag_name -R actions/runner -p "actions-runner-win-x64-$version.zip" -D $cache | Out-Null
    }
    if ($release.body -match '<!-- BEGIN SHA win-x64 -->\s*([0-9a-fA-F]{64})\s*<!-- END SHA win-x64 -->') {
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($actual -ne $Matches[1].ToUpper()) {
            Remove-Item $zip -Force
            throw "Checksum mismatch for $zip; deleted it. Run again to re-download."
        }
    } else {
        Write-Warning "Release $version lists no win-x64 checksum; using the zip unverified."
    }
    $zip
}

function Remove-RunnerService([string]$ServiceName, [string]$Folder) {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe delete $ServiceName failed (exit $LASTEXITCODE)." }
    }
    Remove-Item (Join-Path $Folder '.service') -Force -ErrorAction SilentlyContinue
}

function Clear-LocalRegistration([string]$Folder) {
    # What config.cmd remove deletes locally; used when GitHub no longer knows the runner, so config.cmd remove can't run.
    foreach ($file in '.runner', '.runner_migrated', '.credentials', '.credentials_rsaparams', '.credentials_migrated', '.service') {
        Remove-Item (Join-Path $Folder $file) -Force -ErrorAction SilentlyContinue
    }
}

function Read-Inventory {
    if (-not (Test-Path $script:InventoryPath)) { return @() }
    # PowerShell 5.1 hands a JSON array down the pipeline as one object; ForEach-Object unrolls it.
    @((Get-Content $script:InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
}

function Write-Inventory($Entries) {
    $sorted = @($Entries | Sort-Object repo, name)
    # ConvertTo-Json on PowerShell 5.1 unwraps one-item arrays, so the brackets are added by hand.
    $json = if ($sorted.Count -eq 0) { '[]' } else { '[' + (($sorted | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ",`n ") + ']' }
    [IO.File]::WriteAllText($script:InventoryPath, $json + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Set-InventoryEntry([string]$Name, [string]$Repo, [string[]]$Labels, [string]$Folder) {
    $entries = @(Read-Inventory | Where-Object { $_.name -ne $Name -or $_.repo -ne $Repo })
    $entries += [pscustomobject]@{ name = $Name; repo = $Repo; labels = @($Labels); folder = $Folder }
    Write-Inventory $entries
}

function Remove-InventoryEntry([string]$Name, [string]$Repo) {
    Write-Inventory @(Read-Inventory | Where-Object { $_.name -ne $Name -or $_.repo -ne $Repo })
}

Export-ModuleMember -Function * -Variable ServiceAccount
