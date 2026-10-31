# Manages the Linux self-hosted runners on this computer: Docker Desktop containers built from GitHub's runner image.
# Double-click "LinuxRunners.cmd" for the menu, or run: .\LinuxRunners.ps1 add|remove|status|adopt ... (see README).
# Runner names are <host>-linux-<n> (host = this computer's name, lowercased; -Prefix overrides it).
# Each runner is a container and a volume (the runner's files and work folder), both named gh-runner-<runner name>.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('menu', 'add', 'remove', 'status', 'adopt')][string]$Command = 'menu',
    # A number (2 -> <host>-linux-2) or a runner name. For remove: also a container name. For adopt: a container name.
    [Parameter(Position = 1)][string]$Runner,
    [string]$Repo,     # owner/name, for a repository runner
    [string]$Org,      # organization name, for an organization runner (instead of -Repo)
    [string]$Target,   # reads defaults from targets\<Target>.local.json (git-ignored) or targets\<Target>.json
    [string]$Prefix = [Environment]::MachineName,
    [string]$Labels = 'docker',
    # Per-container limits. About 4 GB suits one Gradle build; '' or 0 means no limit. Containers a job starts on
    # the host's Docker engine (services, docker build) are siblings and don't count against these.
    [string]$Memory = '4g',
    [double]$Cpus = 2,
    # Read the registration token from the clipboard instead of typing it. The clipboard is cleared afterwards.
    [switch]$FromClipboard,
    # Take over a name GitHub already has registered (e.g. after rebuilding a runner). Off by default so adding
    # can't silently steal the registration of a runner that is still running somewhere.
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$Bound = $PSBoundParameters   # what the caller passed; a target file never overrides these
# The only place the runner version lives. It is used for new runners only: a running runner updates itself
# into its volume, so existing runners don't need a new image.
$Image = 'ghcr.io/actions/actions-runner:2.338.0'
$Tag = 'actions-runners.name'   # container label holding the runner name; marks containers this script manages

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($question) { (Read-Host "$question (y/N)") -match '^y' }

# Runs docker only to test whether it succeeds. Windows PowerShell turns a redirected stderr line from a native
# command into an error record, and with ErrorActionPreference Stop that throws (for example "no such volume" when
# checking that a volume is free), so this lowers the preference for the probe alone and reads the exit code.
function Test-Docker {
    $ErrorActionPreference = 'Continue'
    & docker @args *> $null
    $LASTEXITCODE -eq 0
}

function Invoke-Docker {
    $out = & docker @args
    if ($LASTEXITCODE -ne 0) { throw "docker $($args[0]) failed (exit $LASTEXITCODE)." }
    $out
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker not found. Install Docker Desktop.' }
    if (-not (Test-Docker info --format '{{.ServerVersion}}')) { throw 'Docker Desktop is not running. Start it, wait for "Engine running", and try again.' }
}

# Fills parameters the caller didn't pass from the target file, so command-line values always win.
function Import-Target {
    if (-not $Target) { return }
    $file = @("$PSScriptRoot\targets\$Target.local.json", "$PSScriptRoot\targets\$Target.json") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $file) { throw "No targets\$Target.local.json or targets\$Target.json. Copy targets\example.json to start one." }
    $cfg = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in 'Repo', 'Org', 'Prefix', 'Labels', 'Memory', 'Cpus') {
        $value = $cfg.($key.ToLower())
        if ($null -ne $value -and -not $Bound.ContainsKey($key)) { Set-Variable -Scope Script -Name $key -Value $value }
    }
}

# The registration URL and the GitHub page listing the runners, for a repository or an organization.
function Get-Scope {
    if ($Repo -and $Org) { throw 'Give -Repo or -Org, not both.' }
    if ($Repo) {
        $r = $Repo.Trim() -replace '^https://github\.com/', '' -replace '/$', ''
        if ($r -notmatch '^[\w.-]+/[\w.-]+$') { throw "'$Repo' isn't owner/name." }
        return @{ Url = "https://github.com/$r"; Page = "https://github.com/$r/settings/actions/runners" }
    }
    if ($Org) {
        if ($Org -notmatch '^[\w.-]+$') { throw "'$Org' isn't an organization name." }
        return @{ Url = "https://github.com/$Org"; Page = "https://github.com/organizations/$Org/settings/actions/runners" }
    }
    throw 'Say where to register: -Repo owner/name, -Org name, or -Target name.'
}

function Resolve-Name($value) {
    $name = if ($value -match '^\d+$') { "$($Prefix.ToLower())-linux-$value" } else { $value.Trim() }
    if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw "'$name' isn't a valid runner name." }
    $name
}

# Every runner container: managed ones (with the label) and hand-made ones using the runner image.
function Get-Containers {
    $ps = @(Invoke-Docker ps -a --no-trunc --format '{{json .}}' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if (-not $ps.Count) { return }
    $inspect = @('inspect') + @($ps.ID)
    $all = (Invoke-Docker @inspect) -join "`n" | ConvertFrom-Json
    foreach ($c in $ps) {
        $info = $all | Where-Object { $_.Id -eq $c.ID } | Select-Object -First 1
        $name = $info.Config.Labels.$Tag
        if (-not $name -and $info.Config.Image -notlike 'ghcr.io/actions/actions-runner*') { continue }
        $vol = $info.Mounts | Where-Object { $_.Destination -eq '/home/runner' -and $_.Type -eq 'volume' } | Select-Object -First 1
        [pscustomobject]@{ Container = $c.Names; Runner = $name; Managed = [bool]$name; State = $c.Status; Volume = $vol.Name
            Page = $info.Config.Labels.'actions-runners.page'; Memory = $info.HostConfig.Memory; Cpus = $info.HostConfig.NanoCpus / 1e9 }
    }
}

function Show-Status {
    $rows = @(Get-Containers)
    Write-Host ''
    foreach ($r in $rows) {
        $who = if ($r.Managed) { $r.Runner } else { '(not adopted)' }
        $mem = if ($r.Memory) { '{0:0.#}g' -f ($r.Memory / 1GB) } else { 'no limit' }
        $cpu = if ($r.Cpus) { "$($r.Cpus) cpus" } else { 'no limit' }
        $color = if ($r.Managed -and $r.State -like 'Up*') { 'Gray' } else { 'Yellow' }
        Write-Host ('  {0,-32} {1,-22} {2,-22} {3,-9} {4,-9} {5}' -f $r.Container, $who, $r.State, $mem, $cpu, $r.Volume) -ForegroundColor $color
    }
    if (-not $rows.Count) { Write-Host '  No Linux runner containers on this computer.' }
    Write-Host ''
}

function Read-Token {
    if ($FromClipboard) {
        $plain = (Get-Clipboard -Raw).Trim()
        Set-Clipboard -Value ' '
        if (-not $plain) { throw 'The clipboard is empty. Copy the token from GitHub first.' }
        return $plain
    }
    $secure = Read-Host 'Registration token (input hidden)' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $secure.Dispose() }
}

# Starts the long-running container. It only runs run.sh: registration already lives in the volume, so the
# container holds no token (docker inspect shows nothing secret).
function Start-RunnerContainer($container, $runner, $volume, $page) {
    $run = @('run', '-d', '--name', $container, '--restart', 'unless-stopped', '--group-add', '0',
        '-v', '/var/run/docker.sock:/var/run/docker.sock', '-v', "${volume}:/home/runner",
        '--label', "$Tag=$runner", '--label', "actions-runners.page=$page",
        '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3')
    if ($Memory -and $Memory -ne '0') { $run += @('--memory', $Memory) }
    if ($Cpus -gt 0) { $run += @('--cpus', "$Cpus") }
    $run += @('--entrypoint', 'bash', $Image, '-c', 'cd /home/runner && exec ./run.sh')
    Invoke-Docker @run | Out-Null
}

function Get-NextNumber {
    $pattern = "^$([regex]::Escape($Prefix.ToLower()))-linux-(\d+)$"
    $used = @(Get-Containers | Where-Object { $_.Runner -match $pattern } | ForEach-Object { [int]($_.Runner -replace $pattern, '$1') })
    $n = 1
    while ($used -contains $n) { $n++ }
    $n
}

function Add-LinuxRunner($value) {
    $scope = Get-Scope
    if (-not $value) { $value = "$(Get-NextNumber)" }
    $name = Resolve-Name $value
    $box = "gh-runner-$name"
    if (@(Get-Containers).Container -contains $box) { throw "A container named $box already exists. Remove it first, or pick another number." }
    if (Test-Docker volume inspect $box) { throw "A volume named $box is left over. Delete it first: docker volume rm $box" }
    $labelList = ($Labels -replace '\s', '').Trim(',')

    Write-Host "Get a token: $($scope.Page)/new (the --token value; it expires in an hour)."
    $token = Read-Token
    try {
        Step "Registering $name for $($scope.Url)"
        # The token goes in on stdin of a throwaway container, so it never appears in a command line,
        # an environment variable or the runner container's config. The volume keeps the registration.
        # No double quotes in $cfg: Windows PowerShell mangles them in native arguments. Tokens are alphanumeric.
        $cfg = "cd /home/runner && read -r RUNNER_TOKEN && RUNNER_TOKEN=`${RUNNER_TOKEN%`$'\r'} && " +
            "./config.sh --unattended --url '$($scope.Url)' --token `$RUNNER_TOKEN --name '$name' --work _work" +
            $(if ($labelList) { " --labels '$labelList'" } else { '' }) + $(if ($Replace) { ' --replace' } else { '' })
        $token | & docker run --rm -i -v "${box}:/home/runner" --entrypoint bash $Image -c $cfg
        if ($LASTEXITCODE -ne 0) {
            Test-Docker volume rm $box | Out-Null
            throw 'config.sh failed. Check the token is fresh and for this target; if the name is taken on GitHub, delete it there or use -Replace.'
        }
    } finally { $token = $null; [GC]::Collect() }

    Step "Starting $box"
    Start-RunnerContainer $box $name $box $scope.Page
    $runsOn = @('self-hosted', 'Linux', 'X64') + @($labelList -split ',' | Where-Object { $_ })
    Write-Host "Done. Workflows can use: runs-on: [$($runsOn -join ', ')]" -ForegroundColor Green
}

function Remove-LinuxRunner($value) {
    if (-not $value) { throw 'Give the runner number, runner name or container name to remove.' }
    $match = @(Get-Containers | Where-Object { $_.Container -eq $value -or $_.Runner -eq $value -or $_.Runner -eq (Resolve-Name $value) })
    if (-not $match.Count) { throw "No runner container for '$value'. Run: .\LinuxRunners.ps1 status" }
    $c = $match[0]
    $label = if ($c.Runner) { $c.Runner } else { $c.Container }
    if (-not (Ask "Delete container $($c.Container) and volume $($c.Volume) (runner $label)?")) { return }
    Invoke-Docker rm -f $c.Container | Out-Null
    if ($c.Volume) { Invoke-Docker volume rm $c.Volume | Out-Null }
    Write-Host "Removed $label from this PC." -ForegroundColor Green
    $where = if ($c.Page) { $c.Page } else { 'the repository or organization: Settings > Actions > Runners' }
    Write-Host "Now delete runner $label on GitHub too: $where" -ForegroundColor Yellow
}

# Recreates a hand-made runner container under this script's management, keeping its container name, volume and
# registration: no new token, no rename. It only gains the management label and the limits.
function Invoke-Adopt($value) {
    $c = @(Get-Containers | Where-Object { $_.Container -eq $value -and -not $_.Managed })[0]
    if (-not $c) { throw "No unadopted runner container named '$value'. Run: .\LinuxRunners.ps1 status" }
    if (-not $c.Volume) { throw "$value has no volume on /home/runner, so its registration would be lost. Add it again instead." }
    $json = Invoke-Docker run --rm -v "$($c.Volume):/home/runner" --entrypoint cat $Image /home/runner/.runner
    $info = ($json -join "`n").TrimStart([char]0xFEFF) | ConvertFrom-Json
    $scope = $info.gitHubUrl -replace '^https://github\.com/', ''
    $page = if ($scope -like '*/*') { "$($info.gitHubUrl)/settings/actions/runners" } else { "https://github.com/organizations/$scope/settings/actions/runners" }
    if (-not (Ask "Recreate $value (runner $($info.agentName), $($info.gitHubUrl)) on volume $($c.Volume)?")) { return }
    Invoke-Docker rm -f $c.Container | Out-Null
    Start-RunnerContainer $c.Container $info.agentName $c.Volume $page
    Write-Host "Adopted $($info.agentName): same container name, volume and registration." -ForegroundColor Green
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host 'Linux Docker runners: 1) Status  2) Add  3) Remove  4) Adopt existing container  Q) Quit' -ForegroundColor Cyan
        $choice = Read-Host 'Choose'
        try {
            switch ($choice) {
                '1' { Show-Status }
                '2' {
                    $t = (Read-Host 'Target name from targets\ (Enter to type a repository instead)').Trim()
                    if ($t) { $script:Target = $t; Import-Target }
                    else { $script:Repo = (Read-Host 'Repository (owner/name)').Trim() }
                    $pick = (Read-Host "Runner number or name [$($Prefix.ToLower())-linux-$(Get-NextNumber)]").Trim()
                    $l = (Read-Host "Labels, comma-separated [$Labels]").Trim(); if ($l) { $script:Labels = $l }
                    $m = (Read-Host "Memory limit, 0 for none [$Memory]").Trim(); if ($m) { $script:Memory = $m }
                    $p = (Read-Host "CPU limit, 0 for none [$Cpus]").Trim(); if ($p) { $script:Cpus = [double]$p }
                    $script:FromClipboard = Ask 'Read the token from the clipboard (instead of typing it)?'
                    Add-LinuxRunner $pick
                }
                '3' { Show-Status; Remove-LinuxRunner (Read-Host 'Runner or container name').Trim() }
                '4' { Show-Status; Invoke-Adopt (Read-Host 'Container name to adopt').Trim() }
                { $_ -match '^[qQ]?$' } { return }
            }
        } catch {
            Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

try {
    Assert-Docker
    Import-Target
    switch ($Command) {
        'menu' { Show-Menu }
        'add' { Add-LinuxRunner $Runner }
        'remove' { Remove-LinuxRunner $Runner }
        'status' { Show-Status }
        'adopt' { Invoke-Adopt $Runner }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Command -eq 'menu') { Read-Host 'Press Enter to close' }
    exit 1
}
