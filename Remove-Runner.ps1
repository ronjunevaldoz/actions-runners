<#
.SYNOPSIS
Deregisters a runner: removes its service, unregisters it from GitHub (config.cmd remove) and drops it from runners.json.

.DESCRIPTION
With a local folder: stops and deletes the service, then runs config.cmd remove. If GitHub already forgot the runner,
the local registration files are cleared instead. The folder (binaries and _work) is kept unless -DeleteFolder.
Without a local folder (runner lives on another machine or is gone): deletes it on GitHub through the API; give -Repo.
Asks before each change; -Confirm:$false skips that.

.EXAMPLE
.\Remove-Runner.ps1 -Name golearnph-runner
.EXAMPLE
.\Remove-Runner.ps1 -Name old-runner -Repo ronjunevaldoz/golearnph   # API delete, no local folder
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Name,
    # Needed when no local folder has this runner, or when several repos have a runner with this name.
    [string]$Repo,
    [switch]$DeleteFolder,
    # Delete through the API even if GitHub reports the runner online (it may be running on another machine).
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force
Assert-Gh
if ($Repo) { $Repo = Resolve-Repo $Repo }

$local = @(Get-LocalRunner | Where-Object { $_.Name -eq $Name -and (-not $Repo -or (Resolve-Repo $_.Repo) -eq $Repo) })
if ($local.Count -gt 1) {
    throw "Several folders hold a runner named ${Name}: $($local.Folder -join ', '). Pass -Repo."
}

if ($local) {
    $l = $local[0]
    $repoName = Resolve-Repo $l.Repo
    if (-not $PSCmdlet.ShouldProcess("$Name ($repoName) in $($l.Folder)", 'Remove service and deregister')) { return }
    if ($l.ServiceName) { Assert-Admin; Remove-RunnerService $l.ServiceName $l.Folder }

    $onGitHub = @(Get-RemoteRunner $repoName) | Where-Object { $_.id -eq $l.AgentId }
    if ($onGitHub) {
        Push-Location $l.Folder
        try { & .\config.cmd remove --token (New-RunnerToken $repoName remove) } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "config.cmd remove failed (exit $LASTEXITCODE)." }
    } else {
        Write-Host 'GitHub no longer has this runner; clearing the local registration files.'
        Clear-LocalRegistration $l.Folder
    }
    Remove-InventoryEntry -Name $Name -Repo $repoName

    if ($DeleteFolder -and $PSCmdlet.ShouldProcess($l.Folder, 'Delete folder (runner binaries and _work)')) {
        Remove-Item $l.Folder -Recurse -Force
    }
    Write-Host "Removed $Name from $repoName." -ForegroundColor Green
    return
}

if (-not $Repo) { throw "No folder on this computer has a runner named $Name. Pass -Repo to delete it on GitHub." }
$r = @(Get-RemoteRunner $Repo) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
if (-not $r) { throw "$Repo has no runner named $Name." }
if ($r.status -eq 'online' -and -not $Force) {
    throw "$Name is online, so it's running somewhere. Remove it on that machine, or pass -Force to delete it here anyway."
}
if ($PSCmdlet.ShouldProcess("$Name (id $($r.id), $($r.status)) in $Repo", 'Delete on GitHub')) {
    Invoke-Gh api -X DELETE "repos/$Repo/actions/runners/$($r.id)" | Out-Null
    Remove-InventoryEntry -Name $Name -Repo $Repo
    Write-Host "Deleted $Name from $Repo on GitHub." -ForegroundColor Green
}
