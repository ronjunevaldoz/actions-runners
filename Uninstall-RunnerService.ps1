<#
.SYNOPSIS
Stops and deletes a runner's Windows service but keeps it registered, so it can still be started by hand with run.cmd.
To get rid of the runner itself, use Remove-Runner.ps1.

.EXAMPLE
.\Uninstall-RunnerService.ps1 -Name golearnph-runner
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Name)
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force
Assert-Admin

$l = @(Get-LocalRunner | Where-Object { $_.Name -eq $Name })
if ($l.Count -ne 1) { throw "Expected one local runner named $Name, found $($l.Count). See Get-Runners.ps1." }
$l = $l[0]
if (-not $l.ServiceName) { Write-Host "$Name has no service."; return }
if ($PSCmdlet.ShouldProcess($l.ServiceName, 'Stop and delete service')) {
    Remove-RunnerService $l.ServiceName $l.Folder
    Write-Host "Service removed. Start the runner by hand with $($l.Folder)\run.cmd" -ForegroundColor Green
}
