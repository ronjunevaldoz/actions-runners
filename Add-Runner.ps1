<#
.SYNOPSIS
Registers a self-hosted runner for a repository and (by default) installs it as a Windows service.

.EXAMPLE
.\Add-Runner.ps1 -Repo my-org/my-app -Labels android,gradle
.EXAMPLE
.\Add-Runner.ps1 -Repo my-org/my-app -Name my-app-runner -Replace   # re-register an existing runner
#>
[CmdletBinding()]
param(
    # owner/name. Asked for when omitted (the double-click launcher relies on that).
    [string]$Repo,
    # Defaults to <repo>-runner, with -2, -3... if GitHub already has that name.
    [string]$Name,
    # Extra labels; self-hosted, Windows and X64 are always added by the runner.
    [string[]]$Labels = @(),
    # Defaults to the runner's existing folder, else <RunnerRoot>\<Name>.
    [string]$Folder,
    # Register only; start it yourself with run.cmd. Doesn't need admin.
    [switch]$NoService,
    # Re-register a runner that already exists (same name on GitHub, or the folder is already registered).
    [switch]$Replace
)
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force

if (-not $NoService) { Assert-Admin }
Assert-Gh
if (-not $Repo) { $Repo = Read-Host 'Which repository? (owner/name)' }
$Repo = Resolve-Repo $Repo.Trim()

$remote = @(Get-RemoteRunner $Repo)
if (-not $Name) {
    $base = ($Repo -split '/')[1] + '-runner'
    $Name = $base; $i = 2
    while ($remote.name -contains $Name) { $Name = "$base-$i"; $i++ }
}
if (($remote.name -contains $Name) -and -not $Replace) {
    throw "$Repo already has a runner named $Name. Pick another -Name, or pass -Replace to re-register it."
}

$existing = @(Get-LocalRunner | Where-Object { $_.Name -eq $Name -and $_.Folder -like "$(Get-RunnerRoot)\*" })
if (-not $Folder) { $Folder = if ($existing) { $existing[0].Folder } else { Join-Path (Get-RunnerRoot) $Name } }
if ((Test-Path (Join-Path $Folder '.runner')) -and -not $Replace) {
    throw "$Folder is already registered. Pass -Replace to re-register it, or remove it first with Remove-Runner.ps1."
}
Write-Host "Repo: $Repo    Name: $Name    Folder: $Folder"

if (-not (Test-Path (Join-Path $Folder 'config.cmd'))) {
    $zip = Get-RunnerPackage
    Write-Step "Unpacking the runner into $Folder"
    New-Item -ItemType Directory -Force $Folder | Out-Null
    Expand-Archive $zip -DestinationPath $Folder -Force
}

Push-Location $Folder
try {
    if (Test-Path '.runner') {
        Write-Step 'Removing the old registration first'
        $old = Get-LocalRunner | Where-Object { $_.Folder -eq $Folder }
        if ($old.ServiceName) { Remove-RunnerService $old.ServiceName $Folder }
        $oldRepo = Resolve-Repo $old.Repo
        # config.cmd remove hangs when GitHub has already deleted the runner, so only call it for one GitHub still has.
        if (@(Get-RemoteRunner $oldRepo) | Where-Object { $_.id -eq $old.AgentId }) {
            & .\config.cmd remove --token (New-RunnerToken $oldRepo remove)
            if ($LASTEXITCODE -ne 0) { throw "config.cmd remove failed (exit $LASTEXITCODE)." }
        } else {
            Write-Host 'GitHub no longer has this runner; clearing the local registration files.'
            Clear-LocalRegistration $Folder
        }
    }

    Write-Step "Registering $Name for $Repo"
    $configArgs = @('--url', "https://github.com/$Repo", '--token', (New-RunnerToken $Repo registration),
        '--name', $Name, '--work', '_work', '--unattended')
    if ($Labels.Count) { $configArgs += @('--labels', ($Labels -join ',')) }
    if ($Replace) { $configArgs += '--replace' }
    if (-not $NoService) { $configArgs += @('--runasservice', '--windowslogonaccount', $ServiceAccount) }
    & .\config.cmd @configArgs
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed (exit $LASTEXITCODE)." }
}
finally { Pop-Location }

Set-InventoryEntry -Name $Name -Repo $Repo -Labels $Labels -Folder $Folder
$runsOn = @('self-hosted', 'Windows') + $Labels
Write-Host ''
Write-Host "Done. Jobs with runs-on: [$($runsOn -join ', ')] in $Repo can run here." -ForegroundColor Green
if ($NoService) { Write-Host "Start it with $Folder\run.cmd, or install the service later: .\Install-RunnerService.ps1 -Name $Name" }
