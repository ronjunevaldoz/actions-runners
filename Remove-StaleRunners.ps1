<#
.SYNOPSIS
Cleans up runners that no longer work: offline ones on GitHub with no folder here, and (with -IncludeLocal) local
registrations GitHub has forgotten.

.DESCRIPTION
Asks before each deletion. Run with -WhatIf first to see what it would do.
A runner that's offline because this computer is off, or because it lives on another machine, also looks stale on
GitHub; only confirm the ones you know are dead.

.EXAMPLE
.\Remove-StaleRunners.ps1 -WhatIf
.EXAMPLE
.\Remove-StaleRunners.ps1 -Repo ronjunevaldoz/golearnph -IncludeLocal
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Defaults to every repository with a local runner folder or an entry in runners.json.
    [string[]]$Repo = @(),
    # Also clear local folders whose registration GitHub no longer has (service + .runner/.credentials files).
    [switch]$IncludeLocal,
    # With -IncludeLocal, delete those folders entirely.
    [switch]$DeleteFolder
)
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force
Assert-Gh

$local = @(Get-LocalRunner)
if (-not $Repo.Count) { $Repo = @($local.Repo) + @((Read-Inventory).repo) | Where-Object { $_ } }
$repos = @($Repo | ForEach-Object { Resolve-Repo $_ } | Select-Object -Unique)

foreach ($current in $repos) {
    $remote = @(Get-RemoteRunner $current)
    $here = @($local | Where-Object { (Resolve-Repo $_.Repo) -eq $current })

    foreach ($r in $remote | Where-Object { $_.status -eq 'offline' -and $here.AgentId -notcontains $_.id }) {
        if ($PSCmdlet.ShouldProcess("$($r.name) (id $($r.id), offline) in $current", 'Delete on GitHub')) {
            Invoke-Gh api -X DELETE "repos/$current/actions/runners/$($r.id)" | Out-Null
            Remove-InventoryEntry -Name $r.name -Repo $current
            Write-Host "Deleted $($r.name) from $current." -ForegroundColor Green
        }
    }

    if (-not $IncludeLocal) { continue }
    foreach ($l in $here | Where-Object { $remote.id -notcontains $_.AgentId }) {
        if ($PSCmdlet.ShouldProcess("$($l.Name) in $($l.Folder) (GitHub no longer has it)", 'Clear local registration')) {
            if ($l.ServiceName) { Assert-Admin; Remove-RunnerService $l.ServiceName $l.Folder }
            Clear-LocalRegistration $l.Folder
            Remove-InventoryEntry -Name $l.Name -Repo $current
            Write-Host "Cleared $($l.Folder)." -ForegroundColor Green
            if ($DeleteFolder -and $l.Folder -like "$(Get-RunnerRoot)\*" -and
                $PSCmdlet.ShouldProcess($l.Folder, 'Delete folder (runner binaries and _work)')) {
                Remove-Item $l.Folder -Recurse -Force
            }
        }
    }
}
