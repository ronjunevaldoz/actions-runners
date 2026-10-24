<#
.SYNOPSIS
Lists runners on this computer and on GitHub side by side, and flags the ones that don't match up.

.DESCRIPTION
Checks every repository that has a local runner folder or an entry in runners.json, plus any passed with -Repo.
Problems column:
  stale-local    registered in a local folder, but GitHub no longer has it (remove with Remove-StaleRunners.ps1 -IncludeLocal)
  stale-remote   offline on GitHub with no folder here (delete with Remove-StaleRunners.ps1)
  no-service     registered here but not installed as a service (Install-RunnerService.ps1)
  not-inventory  works, but runners.json doesn't list it
  legacy-folder  registered outside <RunnerRoot>\<name>; re-add it with Add-Runner.ps1 so it's managed

.EXAMPLE
.\Get-Runners.ps1
.EXAMPLE
.\Get-Runners.ps1 -Repo ronjunevaldoz/golearnph | Format-List
#>
[CmdletBinding()]
param([string[]]$Repo = @())
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force
Assert-Gh

$local = @(Get-LocalRunner)
$inventory = @(Read-Inventory)
$root = Get-RunnerRoot

# Map every name we know (including pre-rename ones in old .runner files) to the repository's current name.
$repoNames = @{}
foreach ($r in @($local.Repo) + @($inventory.repo) + $Repo | Where-Object { $_ } | Select-Object -Unique) {
    try { $repoNames[$r] = Resolve-Repo $r } catch { Write-Warning "Can't read $r ($($_.Exception.Message)); skipping it." }
}

$rows = foreach ($current in ($repoNames.Values | Select-Object -Unique)) {
    $remote = @(Get-RemoteRunner $current)
    $here = @($local | Where-Object { $repoNames[$_.Repo] -eq $current })
    foreach ($r in $remote) {
        $match = $here | Where-Object { $_.AgentId -eq $r.id -and $_.Name -eq $r.name } | Select-Object -First 1
        $problems = @()
        if (-not $match -and $r.status -eq 'offline') { $problems += 'stale-remote' }
        if ($match -and -not $match.ServiceName) { $problems += 'no-service' }
        if ($match -and (Split-Path $match.Folder -Parent) -ne $root) { $problems += 'legacy-folder' }
        if (-not ($inventory | Where-Object { $_.name -eq $r.name -and $_.repo -eq $current })) { $problems += 'not-inventory' }
        [pscustomobject]@{
            Repo     = $current
            Name     = $r.name
            Id       = $r.id
            GitHub   = if ($r.busy) { 'busy' } else { $r.status }
            Service  = if ($match) { $match.ServiceStatus } else { '-' }
            Folder   = if ($match) { $match.Folder } else { '(elsewhere)' }
            Labels   = $r.labels -join ','
            Problems = $problems -join ' '
        }
    }
    foreach ($l in $here | Where-Object { $remote.id -notcontains $_.AgentId }) {
        [pscustomobject]@{
            Repo = $current; Name = $l.Name; Id = $l.AgentId; GitHub = 'missing'; Service = $l.ServiceStatus
            Folder = $l.Folder; Labels = ''; Problems = 'stale-local'
        }
    }
}

# Note: a repository can share runners with another one it was renamed from, so the same Id may show for both names.
$rows | Sort-Object Repo, Name | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
$unregistered = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_*' -and -not (Test-Path (Join-Path $_.FullName '.runner')) }
if ($unregistered) { Write-Host "Folders in $root with no registration: $($unregistered.Name -join ', ')" -ForegroundColor Yellow }
