# "recover" for Runners.ps1 (dot-sourced by it, so it uses its Get-Runners, Get-Remote, Register-Runner and Invoke-Gh):
# finds this PC's Windows runners whose service is stopped, that are offline on GitHub although their service runs,
# that sit idle while their jobs wait in the queue, or that lost their registration, and brings them back.
# Busy and online runners are never touched, and neither is anything outside this PC's runner folders.

# Makes Windows restart a crashed runner service by itself, the Windows side of Docker's restart policy: after a
# minute, up to three times a day. Set on every recover, so runners added before this get it too.
function Set-ServiceRecovery($service) {
    & sc.exe failure $service reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
}

# -Target supplies the repository and labels to keep alive; Windows runners are per repository, so it needs "repo".
function Import-WindowsTarget {
    $script:TargetRepo = $null
    $script:TargetLabels = ''
    if (-not $Target) { return }
    $cfg = Read-TargetFile $Target
    if (-not $cfg.repo) { throw "targets\$Target has no repo; Windows runners are registered per repository." }
    $script:TargetRepo = Resolve-Repo $cfg.repo
    $script:TargetLabels = "$($cfg.labels)" -replace '\s', ''
}

# The extra labels to re-register with: the runner's own when GitHub still has it, else the target's when it is for
# the same repository, else none (GitHub forgets the labels of a runner it deleted).
function Get-ExtraLabels($row) {
    if ($row.Labels) { return @($row.Labels -split ',' | Where-Object { @('self-hosted', 'Windows', 'X64') -notcontains $_ }) -join ',' }
    if ($script:TargetRepo -eq $row.Repo) { return $script:TargetLabels }
    ''
}

# What is wrong with one runner here, and the fix: Register (again, same name), Restart (the service), Wait (restart
# once the grace period is over) or nothing.
function Get-Diagnosis($r) {
    $svc = $r.Local.Service
    if ($r.State -eq 'gone from GitHub') { return 'deregistered on GitHub', 'Register' }
    if (-not $svc) { return 'no service on this PC', 'Register' }
    if ($svc.Status -ne 'Running') { return "service $($svc.Status)", 'Restart' }
    if ($r.State -eq 'busy') { return 'healthy (busy)', '' }
    if ($r.State -ne 'online') { return "service running, $($r.State) on GitHub", 'Wait' }
    if (Test-Starved $r.Repo @($r.Labels -split ',')) { return 'idle while its jobs wait in the queue', 'Wait' }
    'healthy', ''
}

function Invoke-Recover {
    Step "Recover $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Import-WindowsTarget
    Read-Grace 'windows'
    $mine = '^' + [regex]::Escape($env:COMPUTERNAME.ToLower()) + '-windows-\d+$'
    $rows = @(Get-Runners)
    # With a target, also look at its repository when no runner folder here points at it any more.
    if ($script:TargetRepo -and @($rows | ForEach-Object { $_.Repo }) -notcontains $script:TargetRepo) {
        $rows += @(Get-Remote $script:TargetRepo | ForEach-Object { [pscustomobject]@{ Repo = $script:TargetRepo; Name = $_.name; Local = $null; State = $_.status } })
    }
    $report = @()
    $acted = $false
    foreach ($r in $rows) {
        $key = "$($r.Repo)/$($r.Name)"
        if (-not $r.Local) {
            # Registered on GitHub with this PC's naming but nothing here. Not recreated automatically: it may have
            # been removed on purpose, and a crash leaves the folder behind.
            if ($r.Name -match $mine -and $r.State -like 'offline*') {
                $report += New-ReportRow $r.Name $key 'on GitHub, missing on this PC' 'none: add it again (same name) or delete it on GitHub'
            }
            continue
        }
        if ($r.Local.Service) { Set-ServiceRecovery $r.Local.Service.Name }
        $problem, $fix = Get-Diagnosis $r
        if ($fix -eq 'Wait') {
            if (Test-Due $key) { $fix = 'Restart' }
            else { $report += New-ReportRow $r.Name $key $problem "none yet: may be updating, retry in $GraceMinutes min"; continue }
        }
        if (-not $fix) { $report += New-ReportRow $r.Name $key $problem 'none'; continue }
        if ($fix -eq 'Register' -and $r.Local.Folder -notlike "$root\*") {
            $report += New-ReportRow $r.Name $key $problem "none: old folder $($r.Local.Folder), add it again from the menu"
            continue
        }
        $verb = if ($fix -eq 'Restart') { 'Restart the service' } else { 'Re-register it under the same name' }
        if (-not (Confirm-Fix $r.Name $problem $verb)) { $report += New-ReportRow $r.Name $key $problem 'skipped'; continue }
        try {
            if ($fix -eq 'Restart') {
                Restart-Service $r.Local.Service.Name -Force
                $did = 'restarted the service'
            } else {
                $labels = Get-ExtraLabels $r
                Register-Runner $r.Repo $r.Name $labels $true | Out-Host
                $did = 're-registered, labels: ' + $(if ($labels) { $labels } else { 'defaults only' })
            }
            $acted = $true
            $report += New-ReportRow $r.Name $key $problem $did -Fixed
        } catch {
            $report += New-ReportRow $r.Name $key $problem "failed: $($_.Exception.Message)"
        }
    }
    Save-Grace 'windows'

    if ($acted) {
        Write-Host 'Waiting 30 seconds for the runners to come online...'
        Start-Sleep -Seconds 30
        $now = @(Get-Runners)
        foreach ($x in @($report | Where-Object { $_.Fixed })) {
            $n = $now | Where-Object { "$($_.Repo)/$($_.Name)" -eq $x.Key } | Select-Object -First 1
            $svc = if ($n -and $n.Local -and $n.Local.Service) { $n.Local.Service.Status } else { 'no service' }
            $x.After = if ($n) { "$($n.State), service $svc" } else { 'not found' }
        }
    }
    Write-Report $report
}
