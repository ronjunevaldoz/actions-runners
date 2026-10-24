<#
.SYNOPSIS
Installs an already-registered runner as a Windows service running as NETWORK SERVICE, the way config.cmd --runasservice does.

.EXAMPLE
.\Install-RunnerService.ps1 -Name my-app-runner
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Name)
Import-Module (Join-Path $PSScriptRoot 'RunnerTools.psm1') -Force
Assert-Admin

$l = @(Get-LocalRunner | Where-Object { $_.Name -eq $Name })
if ($l.Count -ne 1) { throw "Expected one local runner named $Name, found $($l.Count). See Get-Runners.ps1." }
$l = $l[0]
if ($l.ServiceName) { Write-Host "$Name already runs as $($l.ServiceName) ($($l.ServiceStatus))."; return }

$serviceName = Get-ServiceName $l.Repo $Name
$exe = Join-Path $l.Folder 'bin\RunnerService.exe'
if (-not (Test-Path $exe)) { throw "$exe is missing; the folder isn't a complete runner install." }

Write-Step "Granting $ServiceAccount access to $($l.Folder)"
& icacls.exe $l.Folder /grant '*S-1-5-20:(OI)(CI)M' /T /Q | Out-Null   # S-1-5-20 = NETWORK SERVICE
if ($LASTEXITCODE -ne 0) { throw "icacls failed (exit $LASTEXITCODE)." }

Write-Step "Creating service $serviceName"
& sc.exe create $serviceName binPath= "`"$exe`"" start= delayed-auto obj= $ServiceAccount DisplayName= "GitHub Actions Runner ($($serviceName -replace '^actions\.runner\.', ''))" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed (exit $LASTEXITCODE)." }
& sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/none/0 | Out-Null
[IO.File]::WriteAllText((Join-Path $l.Folder '.service'), $serviceName)
Start-Service $serviceName
Write-Host "$Name now runs as $serviceName." -ForegroundColor Green
