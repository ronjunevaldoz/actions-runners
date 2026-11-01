# Shared by Runners.ps1 and LinuxRunners.ps1 (dot-sourced): target files, the watchdog scheduled task that runs
# "recover" every few minutes, its log, the grace period for runners that may only be updating themselves, the
# queued-jobs check and the before/after report. $kind is 'windows' or 'linux'.
$WatchdogDir = Join-Path $env:LOCALAPPDATA 'actions-runners'
$TargetsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'targets'
$TaskPath = '\actions-runners\'
# A runner whose host is up but which is offline on GitHub may just be updating itself (it drops offline for a minute).
# The watchdog only restarts it once it has seen it like that for this long, so on its second run at the earliest.
$GraceMinutes = 4
# A job counts as stuck once it has been queued this long while an idle, online runner with its labels sits there.
$QueuedSeconds = 600

# targets\<name>.local.json (git-ignored) or targets\<name>.json, parsed.
function Read-TargetFile($name) {
    $file = @("$TargetsDir\$name.local.json", "$TargetsDir\$name.json") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $file) { throw "No targets\$name.local.json or targets\$name.json. Copy targets\example.json to start one." }
    Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-WatchdogLog($kind) { Join-Path $WatchdogDir "$kind-watchdog.log" }

function Get-WatchdogTasks($kind) {
    @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$kind-recover*" })
}

# One task per script and target (<kind>-recover or <kind>-recover-<target>), running "recover -Unattended" every
# $minutes. It runs as you and only while you're signed in: gh keeps its login in your profile, and Docker Desktop
# only runs then anyway. conhost --headless keeps a console window from flashing up on every run.
function Install-Watchdog($kind, $script, $target, $runLevel, $minutes = 5) {
    if ($target -and $target -notmatch '^[\w.-]+$') { throw "'$target' isn't a target name." }
    if ($target) { Read-TargetFile $target | Out-Null }
    $name = "$kind-recover" + $(if ($target) { "-$target" } else { '' })
    $arg = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" recover -Unattended"
    if ($target) { $arg += " -Target $target" }
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arg -WorkingDirectory (Split-Path -Parent $script)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $minutes)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel $runLevel
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "Watchdog on: task $TaskPath$name runs recover every $minutes minutes while you're signed in." -ForegroundColor Green
    Write-Host "Its reports go to $(Get-WatchdogLog $kind)"
}

function Uninstall-Watchdog($kind) {
    $tasks = Get-WatchdogTasks $kind
    if (-not $tasks.Count) { Write-Host 'No watchdog installed.'; return }
    foreach ($t in $tasks) {
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t.TaskName -Confirm:$false
        Write-Host "Watchdog off: removed task $TaskPath$($t.TaskName)." -ForegroundColor Green
    }
}

# Menu prompt for a saved target: lists targets\*.json (example.json aside) by number. Returns '' for none.
function Select-Target($why) {
    $names = @(Get-ChildItem $TargetsDir -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'example.json' } |
        ForEach-Object { $_.Name -replace '(\.local)?\.json$', '' } | Select-Object -Unique)
    if (-not $names.Count) { return '' }
    Write-Host "Saved targets ($why):"
    $i = 0
    foreach ($n in $names) { $i++; Write-Host ('  {0}) {1}' -f $i, $n) }
    $pick = (Read-Host 'Target number or name (Enter for none)').Trim()
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $names.Count) { return $names[[int]$pick - 1] }
    $pick
}

# Menu entry "Install watchdog": asks for the target and the interval, and confirms before creating the task.
function Read-WatchdogInstall($kind, $script, $runLevel) {
    $tasks = Get-WatchdogTasks $kind
    if ($tasks.Count) { Write-Host "Already installed: $(($tasks.TaskName) -join ', '). The same target replaces its task." -ForegroundColor Yellow }
    $t = Select-Target 'the repository and labels to keep alive'
    $m = (Read-Host 'Check every how many minutes [5]').Trim()
    $minutes = if ($m) { [int]$m } else { 5 }
    if ($minutes -lt 1) { throw 'The interval is at least 1 minute.' }
    $for = if ($t) { " for target $t" } else { '' }
    if (-not (Ask "Create a scheduled task that runs recover every $minutes minutes$for while you're signed in?")) { return }
    Install-Watchdog $kind $script $t $runLevel $minutes
}

# Menu entry "Remove watchdog": shows the tasks and asks before removing them.
function Read-WatchdogRemove($kind) {
    $tasks = Get-WatchdogTasks $kind
    if (-not $tasks.Count) { Write-Host 'No watchdog installed.'; return }
    foreach ($t in $tasks) { Write-Host "  $TaskPath$($t.TaskName) ($($t.State))" }
    if (Ask 'Remove the watchdog?') { Uninstall-Watchdog $kind }
}

# "watch": recover in the foreground every $minutes until Ctrl+C, with the watchdog's grace period.
function Start-Watch($minutes, [scriptblock]$recover) {
    $script:Unattended = $true
    while ($true) {
        try { & $recover } catch { Write-Host "Recover failed: $($_.Exception.Message)" -ForegroundColor Red }
        Write-Host "Next check in $minutes minutes (Ctrl+C to stop)."
        Start-Sleep -Seconds ($minutes * 60)
    }
}

# Menu runs ask before each fix: y, N, or a (this one and all the rest). Command-line and watchdog runs don't ask.
$script:Interactive = $false
function Confirm-Fix($runner, $problem, $action) {
    if (-not $script:Interactive -or $script:fixAll) { return $true }
    Write-Host "  $($runner): $problem" -ForegroundColor Yellow
    $a = Read-Host "    $action? (y/N, a = yes to all)"
    if ($a -match '^a') { $script:fixAll = $true }
    $a -match '^[ya]'
}

# Unattended runs append their report to the log; it is rolled over to .old past 1 MB.
function Start-WatchdogLog($kind) {
    New-Item -ItemType Directory -Force $WatchdogDir | Out-Null
    $log = Get-WatchdogLog $kind
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
    Start-Transcript -Path $log -Append | Out-Null
}

# Runners the watchdog saw offline-but-up on its last run, and since when. Only problems still present are kept.
function Read-Grace($kind) {
    $seen = @{}
    $file = Join-Path $WatchdogDir "$kind-pending.json"
    try {
        if (Test-Path $file) {
            (Get-Content $file -Raw | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $seen[$_.Name] = if ($_.Value -is [datetime]) { $_.Value } else { [datetime]::Parse($_.Value, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') } }
        }
    } catch { $seen = @{} }
    $script:seen = $seen
    $script:pending = @{}
    $script:queued = @{}
    $script:fixAll = $false
}

function Save-Grace($kind) {
    if (-not $Unattended) { return }
    New-Item -ItemType Directory -Force $WatchdogDir | Out-Null
    $o = [ordered]@{}
    foreach ($k in $script:pending.Keys) { $o[$k] = $script:pending[$k].ToString('o') }
    ConvertTo-Json ([pscustomobject]$o) | Set-Content (Join-Path $WatchdogDir "$kind-pending.json") -Encoding UTF8
}

# Whether to restart a runner that is up but not working now. A person running recover acts at once; the watchdog
# waits until it has seen the problem for $GraceMinutes.
function Test-Due($key) {
    if (-not $Unattended) { return $true }
    $first = if ($script:seen.ContainsKey($key)) { $script:seen[$key] } else { Get-Date }
    if (((Get-Date) - $first).TotalMinutes -ge $GraceMinutes) { return $true }
    $script:pending[$key] = $first
    $false
}

# Fills $script:queued[$repo] with the label sets (one string array each) of the repository's jobs queued for over
# $QueuedSeconds. Read once per run.
$script:queued = @{}
function Read-StaleQueued($repo) {
    if (-not $script:queued.ContainsKey($repo)) {
        $jobs = @()
        foreach ($id in @(Invoke-Gh api "repos/$repo/actions/runs?status=queued&per_page=20" --jq '.workflow_runs[].id')) {
            if (-not $id) { continue }
            # @tsv rather than join: no double quotes in the filter, which Windows PowerShell mangles in native arguments.
            $lines = Invoke-Gh api "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" --jq ".jobs[] | select((.created_at | fromdateiso8601) < now - $QueuedSeconds) | [.status] + .labels | @tsv"
            foreach ($line in @($lines | Where-Object { $_ })) {
                $f = @($line -split "`t")
                if ($f[0] -eq 'queued') { $jobs += , @($f | Select-Object -Skip 1) }
            }
        }
        $script:queued[$repo] = $jobs
    }
}

# Whether a job has waited long in the queue that this (idle, online) runner's labels would take: GitHub shows the
# runner online, but it isn't picking up work.
function Test-Starved($repo, $labels) {
    Read-StaleQueued $repo
    # Iterates the stored list directly: returning it from a function would unroll a single job into its labels.
    foreach ($job in $script:queued[$repo]) {
        if (-not @($job | Where-Object { $labels -notcontains $_ }).Count) { return $true }
    }
    $false
}

function New-ReportRow($runner, $key, $before, $action, [switch]$Fixed) {
    [pscustomobject]@{ Runner = $runner; Key = $key; Before = $before; Action = $action; After = $before; Fixed = [bool]$Fixed }
}

function Write-Report($rows) {
    Write-Host ''
    if (-not $rows.Count) { Write-Host '  No runners to check on this computer.'; Write-Host ''; return }
    Write-Host ('  {0,-26} {1,-40} {2,-40} {3}' -f 'RUNNER', 'BEFORE', 'ACTION', 'AFTER') -ForegroundColor Cyan
    foreach ($r in $rows) {
        $ok = $r.After -match '^(healthy|online|busy)'
        $color = if ($ok -and $r.Fixed) { 'Green' } elseif ($ok) { 'Gray' } else { 'Yellow' }
        Write-Host ('  {0,-26} {1,-40} {2,-40} {3}' -f $r.Runner, $r.Before, $r.Action, $r.After) -ForegroundColor $color
    }
    $bad = @($rows | Where-Object { $_.After -notmatch '^(healthy|online|busy)' })
    Write-Host ''
    if ($bad.Count) { Write-Host "$($bad.Count) runner(s) still need attention." -ForegroundColor Yellow }
    else { Write-Host 'All runners healthy.' -ForegroundColor Green }
}
