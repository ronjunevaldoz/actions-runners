# "recover" for LinuxRunners.ps1 (dot-sourced by it, so it uses its Get-Containers, Register-Volume and Invoke-Docker):
# finds managed runner containers that exited or were OOM-killed, are stuck restarting, are up but offline on GitHub,
# sit idle while their jobs wait in the queue, or lost their registration, and brings them back. Busy and online
# runners are never touched, and neither are containers this script doesn't manage (status shows "(not adopted)").

function Invoke-Gh {
    $out = & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args[0]) $($args[1]) failed (exit $LASTEXITCODE)." }
    $out
}

function Assert-Gh {
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'recover needs the GitHub CLI: winget install GitHub.cli, then gh auth login.' }
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'gh is not signed in. Run: gh auth login' }
}

# The runners API for a registration, from the GitHub page stored on the container when it was created or adopted.
function Get-ApiScope($page) {
    if ($page -match '^https://github\.com/organizations/([\w.-]+)/') { return "orgs/$($Matches[1])" }
    if ($page -match '^https://github\.com/([\w.-]+/[\w.-]+)/settings/') { return "repos/$($Matches[1])" }
}

# The runners GitHub has registered for a repository or organization, read once per run.
$script:remote = @{}
function Get-Registered($api) {
    if (-not $script:remote.ContainsKey($api)) {
        $lines = Invoke-Gh api "$api/actions/runners?per_page=100" --paginate --jq '.runners[] | {id, name, status, busy, labels: [.labels[].name]}'
        $script:remote[$api] = @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $script:remote[$api]
}

# What is wrong with one container, and the fix: Register (again, same name), Start, Unpause, Restart, Wait (restart
# once the grace period is over) or nothing.
function Get-LinuxDiagnosis($c, $api) {
    $reg = @(Get-Registered $api | Where-Object { $_.name -eq $c.Runner })[0]
    $s = $c.Run.Status
    $oom = if ($c.Run.OOMKilled) { ', OOM-killed' } else { '' }
    if (-not $reg) { return 'deregistered on GitHub', 'Register' }
    if ($s -in 'exited', 'created', 'dead') { return "container $s (exit $($c.Run.ExitCode)$oom)", 'Start' }
    if ($s -eq 'paused') { return 'container paused', 'Unpause' }
    if ($s -ne 'running') { return "container $s$oom", 'Restart' }
    if ($reg.busy) { return 'healthy (busy)', '' }
    if ($reg.status -ne 'online') { return "container up, $($reg.status) on GitHub$oom", 'Wait' }
    if ($api -like 'repos/*' -and (Test-Starved ($api -replace '^repos/', '') @($reg.labels))) { return 'idle while its jobs wait in the queue', 'Wait' }
    'healthy', ''
}

# Re-registers a runner under the same name in its own volume (same container, same _work), with a token fetched by
# gh and passed on stdin like add does. Labels come from -Labels or the target (default docker).
function Reset-Registration($c, $api) {
    $url = $c.Page -replace '/settings/actions/runners$', '' -replace '/organizations/', '/'
    $labelList = ($Labels -replace '\s', '').Trim(',')
    Invoke-Docker stop $c.Container | Out-Null
    $token = Invoke-Gh api -X POST "$api/actions/runners/registration-token" --jq .token
    try { $ok = Register-Volume $c.Volume $c.Runner $url $labelList $token $true $true } finally { $token = $null }
    Invoke-Docker start $c.Container | Out-Null
    if (-not $ok) { throw 'config.sh failed; the next recover tries again.' }
    "re-registered, labels: $labelList"
}

function Invoke-LinuxRecover {
    Assert-Gh
    Step "Recover $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Read-Grace 'linux'
    $script:remote = @{}
    $managed = @(Get-Containers | Where-Object { $_.Managed })
    $report = @()
    $hints = @()
    $acted = $false
    foreach ($c in $managed) {
        # Docker restarts a crashed container by itself only with a restart policy; put it back if it was changed.
        if ($c.Restart -notin 'unless-stopped', 'always') { Invoke-Docker update --restart unless-stopped $c.Container | Out-Null }
        if ($c.Run.OOMKilled -and $c.Memory -gt 0 -and $c.Memory -lt 8GB) {
            $hints += "$($c.Runner) was OOM-killed under a $('{0:0.#}g' -f ($c.Memory / 1GB)) limit. Raise it: docker update --memory 8g --memory-swap 16g $($c.Container)"
        }
        $api = Get-ApiScope $c.Page
        if (-not $api) { $report += New-ReportRow $c.Runner $c.Container 'no GitHub page on the container' 'none: remove and add it again'; continue }
        try {
            $problem, $fix = Get-LinuxDiagnosis $c $api
            if ($fix -eq 'Wait') {
                if (Test-Due $c.Container) { $fix = 'Restart' }
                else { $report += New-ReportRow $c.Runner $c.Container $problem "none yet: may be updating, retry in $GraceMinutes min"; continue }
            }
            if (-not $fix) { $report += New-ReportRow $c.Runner $c.Container $problem 'none'; continue }
            $verb = if ($fix -eq 'Register') { 'Re-register it under the same name' } else { "docker $($fix.ToLower()) $($c.Container)" }
            if (-not (Confirm-Fix $c.Runner $problem $verb)) { $report += New-ReportRow $c.Runner $c.Container $problem 'skipped'; continue }
            $did = switch ($fix) {
                'Register' { Reset-Registration $c $api }
                'Start' { Invoke-Docker start $c.Container | Out-Null; 'docker start' }
                'Unpause' { Invoke-Docker unpause $c.Container | Out-Null; 'docker unpause' }
                'Restart' { Invoke-Docker restart $c.Container | Out-Null; 'docker restart' }
            }
            $acted = $true
            $report += New-ReportRow $c.Runner $c.Container $problem $did -Fixed
        } catch {
            $report += New-ReportRow $c.Runner $c.Container 'check or fix failed' "failed: $($_.Exception.Message)"
        }
    }
    # With -Repo/-Org/-Target: runners GitHub has under this PC's naming but with no container here. Not recreated
    # automatically: the container may have been removed on purpose, and a crash leaves the container behind.
    if ($Repo -or $Org) {
        try {
            $api = Get-ApiScope (Get-Scope).Page
            $mine = "^$([regex]::Escape($Prefix.ToLower()))-linux-\d+$"
            $here = @($managed | ForEach-Object { $_.Runner })
            foreach ($g in @(Get-Registered $api | Where-Object { $_.name -match $mine -and $here -notcontains $_.name -and $_.status -ne 'online' })) {
                $report += New-ReportRow $g.name $g.name 'on GitHub, no container here' 'none: add it again with -Replace, or delete it on GitHub'
            }
        } catch { Write-Host "Couldn't list the target's runners: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Save-Grace 'linux'

    if ($acted) {
        Write-Host 'Waiting 30 seconds for the runners to come online...'
        Start-Sleep -Seconds 30
        $script:remote = @{}
        $now = @(Get-Containers | Where-Object { $_.Managed })
        foreach ($x in @($report | Where-Object { $_.Fixed })) {
            $c = $now | Where-Object { $_.Container -eq $x.Key } | Select-Object -First 1
            if (-not $c) { $x.After = 'container gone'; continue }
            try {
                $reg = @(Get-Registered (Get-ApiScope $c.Page) | Where-Object { $_.name -eq $c.Runner })[0]
                $gh = if (-not $reg) { 'not registered' } elseif ($reg.busy) { 'busy' } else { $reg.status }
            } catch { $gh = 'GitHub unknown' }
            $x.After = "$gh, container $($c.Run.Status)"
        }
    }
    Write-Report $report
    foreach ($h in $hints) { Write-Host $h -ForegroundColor Yellow }
}
