# Manages the self-hosted GitHub Actions runners on this computer, both kinds. Double-click "Runners.cmd" to open the menu.
# Windows-service runners live in C:\actions-runner\<name>, one per repository, each installed as a Windows service.
# Docker runners are Linux containers in Docker Desktop; their functions are LinuxRunners.ps1's (lib\Linux.ps1 and
# lib\RecoverLinux.ps1), so LinuxRunners.ps1 still works on its own.
# Also runs without the menu (as administrator), for scripts:
#   .\Runners.ps1 recover|watch|install-watchdog|uninstall-watchdog [-Target <name>] [-Interval <minutes>]
# recover, watch and the watchdog cover both kinds, and start Docker Desktop when it isn't running.
param(
    [Parameter(Position = 0)][ValidateSet('menu', 'recover', 'watch', 'install-watchdog', 'uninstall-watchdog')][string]$Command = 'menu',
    [string]$Target,      # targets\<Target>.local.json: the repository and labels recover re-registers a runner with
    [switch]$Unattended,  # used by the watchdog task: report goes to its log, offline runners get a grace period
    [int]$Interval = 5    # minutes between checks, for watch and install-watchdog
)
$ErrorActionPreference = 'Stop'
$root = 'C:\actions-runner'
# Older hand-made installs registered straight into these folders; scanned so leftovers there get cleaned up too.
$legacy = @($root, "$env:USERPROFILE\actions-runner")
# Docker Desktop, started by recover and the watchdog when its engine isn't answering, and how long to wait for it.
$DockerDesktopExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
$DockerStartSeconds = 180
$script:DockerEngine = ''

# The Docker runner functions read these, which are LinuxRunners.ps1's parameter defaults; a target fills them in.
$Repo = ''; $Org = ''; $Prefix = [Environment]::MachineName; $Labels = 'docker'; $Memory = '8g'; $Cpus = [double]2
$FromClipboard = $false; $Replace = $false; $Bound = @{}
# Loaded before this script's own functions, so this script's Invoke-Gh (defined below) is the one both use.
. "$PSScriptRoot\lib\Linux.ps1"
. "$PSScriptRoot\lib\RecoverLinux.ps1"

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($question) { (Read-Host "$question (y/N)") -match '^y' }

function Invoke-Gh {
    $out = & gh.exe @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed." }
    $out
}

# Follows renames (old-name -> new-name), so a runner registered before a rename still matches.
$script:repoCache = @{}
function Resolve-Repo($repo) {
    if (-not $script:repoCache[$repo]) { $script:repoCache[$repo] = Invoke-Gh api "repos/$repo" --jq .full_name }
    $script:repoCache[$repo]
}

function Get-Remote($repo) {
    $lines = Invoke-Gh api "repos/$repo/actions/runners?per_page=100" --paginate --jq '.runners[] | {id, name, status, busy, labels: [.labels[].name]}'
    @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-Local {
    $folders = @((Get-ChildItem $root -Directory -ErrorAction SilentlyContinue).FullName) + $legacy | Select-Object -Unique
    foreach ($folder in $folders) {
        $file = Join-Path $folder '.runner'
        if (-not (Test-Path $file)) { continue }
        $info = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $repo = $info.gitHubUrl -replace '^https://github\.com/', ''
        $svcFile = Join-Path $folder '.service'
        $svcName = if (Test-Path $svcFile) { (Get-Content $svcFile -Raw).Trim() } else { "actions.runner.$($repo -replace '/', '-').$($info.agentName)" }
        [pscustomobject]@{ Name = $info.agentName; Id = [int]$info.agentId; Repo = $repo; Folder = $folder
            Service = Get-Service -Name $svcName -ErrorAction SilentlyContinue }
    }
}

# One row per runner, from both sides. State: online/busy/offline, or "gone from GitHub" / "not on this PC".
function Get-Runners {
    $local = @(Get-Local)
    $rows = @()
    foreach ($repo in @($local | ForEach-Object { Resolve-Repo $_.Repo }) | Select-Object -Unique) {
        $remote = Get-Remote $repo
        $here = @($local | Where-Object { (Resolve-Repo $_.Repo) -eq $repo })
        foreach ($r in $remote) {
            $l = $here | Where-Object { $_.Id -eq $r.id -and $_.Name -eq $r.name } | Select-Object -First 1
            $rows += [pscustomobject]@{ Repo = $repo; Name = $r.name; Id = $r.id; Local = $l
                State = if ($r.busy) { 'busy' } elseif (-not $l -and $r.status -eq 'offline') { 'offline, not on this PC' } else { $r.status }
                Labels = $r.labels -join ',' }
        }
        foreach ($l in $here | Where-Object { @($remote.id) -notcontains $_.Id }) {
            $rows += [pscustomobject]@{ Repo = $repo; Name = $l.Name; Id = $l.Id; Local = $l; State = 'gone from GitHub'; Labels = '' }
        }
    }
    @($rows | Sort-Object Repo, Name)
}

# 'none' (Docker Desktop isn't installed), 'down' (installed, engine not answering) or 'up'.
function Get-DockerEngine {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'none' }
    if (Test-Docker info --format '{{.ServerVersion}}') { return 'up' }
    'down'
}

# One row per runner container here (Kind 'docker'), in Get-Runners' shape, with the state of the container and of
# its registration on GitHub: "container exited (exit 137, OOM-killed)", "running, online", "running, offline on
# GitHub", "busy", ... Containers LinuxRunners.ps1 doesn't manage show by container name as "not adopted".
function Get-DockerRunners {
    $script:remote = @{}
    foreach ($c in @(Get-Containers)) {
        $api = $null
        if ($c.Managed) { $api = Get-ApiScope $c.Page }
        $repo = '-'
        $reg = $null
        $gh = ''
        if ($api) {
            $repo = $api -replace '^repos/', '' -replace '^orgs/(.*)$', '$1 (org)'
            try {
                # Under the repository's current name, so it matches the Windows rows after a rename or transfer.
                if ($api -like 'repos/*') { $repo = Resolve-Repo ($api -replace '^repos/', ''); $api = "repos/$repo" }
                $reg = @(Get-Registered $api | Where-Object { $_.name -eq $c.Runner })[0]
                if (-not $reg) { $gh = 'not registered on GitHub' }
                elseif ($reg.busy) { $gh = 'busy' }
                elseif ($reg.status -eq 'online') { $gh = 'online' }
                else { $gh = "$($reg.status) on GitHub" }
            } catch { $gh = 'GitHub unknown' }
        }
        $s = $c.Run.Status
        $oom = if ($c.Run.OOMKilled) { ', OOM-killed' } else { '' }
        if (-not $c.Managed) { $state = "container $s, not adopted" }
        elseif ($s -in 'exited', 'created', 'dead') { $state = "container $s (exit $($c.Run.ExitCode)$oom)" }
        elseif ($s -ne 'running') { $state = "container $s$oom" }
        elseif (-not $api) { $state = 'running, no GitHub page' }
        elseif ($gh -eq 'busy') { $state = 'busy' }
        else { $state = "running, $gh" }
        $name = if ($c.Managed) { $c.Runner } else { $c.Container }
        $id = if ($reg) { $reg.id } else { 0 }
        $labelText = if ($reg) { $reg.labels -join ',' } else { '' }
        [pscustomobject]@{ Kind = 'docker'; Repo = $repo; Name = $name; Id = $id; Local = $null; State = $state; Labels = $labelText; Container = $c }
    }
}

# Every runner of this PC's, both kinds, for List, Remove and Clean up leftovers: Get-Runners' rows (Kind 'windows',
# or '' for one that is only on GitHub) and Get-DockerRunners' rows. A GitHub-only row for a runner whose container is
# here is dropped, as the container's row covers it. While Docker Desktop is down, a GitHub-only offline Linux runner
# that looks like one of this PC's Docker runners (named <host>-linux-..., or labelled docker) says so instead of
# "offline, not on this PC". Sets $script:DockerEngine for Show-Runners.
function Get-AllRunners {
    $script:DockerEngine = Get-DockerEngine
    $docker = @()
    if ($script:DockerEngine -eq 'up') {
        try { $docker = @(Get-DockerRunners) } catch { $script:DockerEngine = "error: $($_.Exception.Message)" }
    }
    $unadopted = @($docker | Where-Object { -not $_.Container.Managed }).Count
    $mine = '^' + [regex]::Escape($env:COMPUTERNAME.ToLower()) + '-linux-'
    $rows = @()
    foreach ($r in @(Get-Runners)) {
        $kind = if ($r.Local) { 'windows' } else { '' }
        $state = $r.State
        if (-not $r.Local) {
            if (@($docker | Where-Object { $_.Name -eq $r.Name -and $_.Repo -eq $r.Repo }).Count) { continue }
            $labelSet = @("$($r.Labels)" -split ',')
            if ($labelSet -contains 'Linux' -and $state -like 'offline*') {
                if ($script:DockerEngine -eq 'down' -and ($r.Name -match $mine -or $labelSet -contains 'docker')) {
                    $kind = 'docker'
                    $state = 'Docker Desktop not running'
                } elseif ($unadopted) {
                    $state = 'offline, may be an unadopted container'
                }
            }
        }
        $rows += [pscustomobject]@{ Kind = $kind; Repo = $r.Repo; Name = $r.Name; Id = $r.Id; Local = $r.Local; State = $state
            Labels = $r.Labels; Container = $null }
    }
    @(@($rows) + @($docker) | Sort-Object Repo, Name)
}

function Show-Runners($rows) {
    Write-Host ''
    if ($rows.Count) {
        Write-Host ('{0,3}  {1,-7} {2,-26} {3,-22} {4,-34} {5,-10} {6}' -f '', 'KIND', 'REPOSITORY', 'RUNNER', 'STATE', 'HOST', 'WHERE') -ForegroundColor Cyan
    }
    $i = 0
    foreach ($r in $rows) {
        $i++
        if ($r.Container) {
            $svc = $r.Container.Run.Status
            $folder = "container $($r.Container.Container)"
        } else {
            $svc = if ($r.Local -and $r.Local.Service) { $r.Local.Service.Status } elseif ($r.Local) { 'no service' } else { '-' }
            $folder = if ($r.Local) { $r.Local.Folder } else { '' }
        }
        $kind = if ($r.Kind) { $r.Kind } else { '-' }
        $color = if ($r.State -in 'online', 'busy', 'running, online') { 'Gray' } else { 'Yellow' }
        Write-Host ('{0,3}. {1,-7} {2,-26} {3,-22} {4,-34} {5,-10} {6}' -f $i, $kind, $r.Repo, $r.Name, $r.State, $svc, $folder) -ForegroundColor $color
    }
    if (-not $rows.Count) { Write-Host '  No runners on this computer.' }
    if ($script:DockerEngine -eq 'down') {
        Write-Host "  Docker Desktop is not running, so its runner containers can't be listed. Recover (5) starts it." -ForegroundColor Yellow
    } elseif ($script:DockerEngine -like 'error*') {
        Write-Host "  Couldn't list the Docker runners: $($script:DockerEngine -replace '^error: ', '')" -ForegroundColor Yellow
    }
    Write-Host ''
}

function Remove-Service($local) {
    if (-not $local.Service) { return }
    if ($local.Service.Status -ne 'Stopped') { Stop-Service $local.Service.Name -Force }
    & sc.exe delete $local.Service.Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't delete service $($local.Service.Name)." }
}

# Undoes a registration in a folder: deletes the runner on GitHub through the API, under the repository's
# current name, then deletes the registration files. config.cmd remove isn't used: it sends the request to the
# address the runner was registered at, which a transferred or renamed repository no longer answers (404 from
# actions/runner-registration), and it hangs when GitHub already deleted the runner.
function Clear-Registration($local) {
    Remove-Service $local
    $repo = Resolve-Repo $local.Repo
    if (Get-Remote $repo | Where-Object { $_.id -eq $local.Id }) {
        Invoke-Gh api -X DELETE "repos/$repo/actions/runners/$($local.Id)" | Out-Null
    }
    foreach ($f in '.runner', '.runner_migrated', '.credentials', '.credentials_rsaparams', '.credentials_migrated', '.service') {
        $path = Join-Path $local.Folder $f
        if (Test-Path $path) { Remove-Item $path -Force }
    }
}

function Get-RunnerZip {
    $cache = "$root\_packages"
    New-Item -ItemType Directory -Force $cache | Out-Null
    $release = Invoke-Gh api repos/actions/runner/releases/latest | ConvertFrom-Json
    $version = $release.tag_name.TrimStart('v')
    $zip = "$cache\actions-runner-win-x64-$version.zip"
    if (-not (Test-Path $zip)) {
        Step "Downloading runner $version"
        Invoke-Gh release download $release.tag_name -R actions/runner -p "actions-runner-win-x64-$version.zip" -D $cache | Out-Null
    }
    if ($release.body -match '<!-- BEGIN SHA win-x64 -->\s*([0-9a-fA-F]{64})') {
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Matches[1].ToUpper()) { Remove-Item $zip; throw 'Runner download is corrupt; deleted it. Try again.' }
    }
    $zip
}

# Registers $name for $repo in the runner's folder (its old one, else C:\actions-runner\<name>) and installs the
# service. Recover reuses it to re-register a broken runner under the same name.
function Register-Runner($repo, $name, $labels, $replace) {
    $old = Get-Local | Where-Object { $_.Name -eq $name -and $_.Folder -like "$root\*" } | Select-Object -First 1
    $dir = if ($old) { $old.Folder } else { "$root\$name" }
    if (-not (Test-Path "$dir\config.cmd")) {
        $zip = Get-RunnerZip
        Step "Unpacking into $dir"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Expand-Archive $zip -DestinationPath $dir -Force
    }
    if ($old) { Step 'Removing the old registration'; Clear-Registration $old }

    Step "Registering $name for $repo"
    $token = Invoke-Gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
    $cfg = @('--url', "https://github.com/$repo", '--token', $token, '--name', $name, '--work', '_work', '--unattended',
        '--runasservice', '--windowslogonaccount', 'NT AUTHORITY\NETWORK SERVICE')
    if ($labels) { $cfg += @('--labels', $labels) }
    if ($replace) { $cfg += '--replace' }
    Push-Location $dir
    try { & .\config.cmd @cfg } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'config.cmd failed.' }
}

function Add-Runner {
    $repo = (Read-Host 'Repository (owner/name)').Trim()
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "'$repo' isn't owner/name." }
    $repo = Resolve-Repo $repo
    $taken = @((Get-Remote $repo).name)
    # The suggested name is the first free <host>-windows-<n> (host = this computer's name), skipping names GitHub has
    # registered and folders already in $root, so taking the default adds a runner instead of replacing one.
    $base = $env:COMPUTERNAME.ToLower() + '-windows-'
    $folders = @((Get-ChildItem $root -Directory -ErrorAction SilentlyContinue).Name)
    for ($n = 1; ($taken -contains "$base$n") -or ($folders -contains "$base$n"); $n++) { }
    $default = "$base$n"
    $name = (Read-Host "Runner name [$default]").Trim()
    if (-not $name) { $name = $default }
    $labels = (Read-Host 'Extra labels, comma-separated (optional, e.g. golearn)').Trim() -replace '\s', ''
    $replace = $false
    if ($taken -contains $name) {
        if (-not (Ask "$repo already has a runner named $name. Replace it?")) { return }
        $replace = $true
    }
    Register-Runner $repo $name $labels $replace
    $runsOn = @('self-hosted', 'Windows') + @($labels -split ',' | Where-Object { $_ })
    Write-Host "Done. Workflows in $repo can use: runs-on: [$($runsOn -join ', ')]" -ForegroundColor Green
}

function Remove-Runner {
    $rows = @(Get-AllRunners | Where-Object { $_.Kind -ne 'docker' })
    Show-Runners $rows
    $pick = Read-Host 'Number to remove (Enter to cancel)'
    if (-not $pick) { return }
    $n = 0
    if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $rows.Count) { throw "No runner number $pick." }
    $r = $rows[$n - 1]
    if (-not (Ask "Remove $($r.Name) from $($r.Repo)?")) { return }
    if ($r.Local) {
        Clear-Registration $r.Local
        if ($r.Local.Folder -like "$root\*" -and (Ask "Also delete $($r.Local.Folder) (runner files and build cache)?")) {
            Remove-Item $r.Local.Folder -Recurse -Force
        }
    } else {
        Invoke-Gh api -X DELETE "repos/$($r.Repo)/actions/runners/$($r.Id)" | Out-Null
    }
    Write-Host "Removed $($r.Name)." -ForegroundColor Green
}

function Clear-Leftovers {
    $stale = @(Get-AllRunners | Where-Object { $_.State -in 'gone from GitHub', 'offline, not on this PC' })
    $empty = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_*' -and -not (Test-Path "$($_.FullName)\.runner") })
    if (-not $stale.Count -and -not $empty.Count) { Write-Host 'Nothing to clean up.' -ForegroundColor Green; return }
    foreach ($r in $stale) {
        $where = if ($r.Local) { $r.Local.Folder } else { 'GitHub only' }
        if (-not (Ask "$($r.Name) ($($r.Repo), $($r.State), $where): remove it?")) { continue }
        if ($r.Local) { Clear-Registration $r.Local } else { Invoke-Gh api -X DELETE "repos/$($r.Repo)/actions/runners/$($r.Id)" | Out-Null }
        Write-Host "  Removed $($r.Name)." -ForegroundColor Green
    }
    foreach ($d in $empty) {
        if (Ask "$($d.FullName) has no runner registered in it. Delete the folder?") {
            Remove-Item $d.FullName -Recurse -Force
            Write-Host "  Deleted $($d.FullName)." -ForegroundColor Green
        }
    }
}

# Starts Docker Desktop and waits up to $DockerStartSeconds for its engine to answer. From an elevated window (this
# menu, the watchdog task) it is started through Explorer, so it runs as you, unelevated, as from the Start menu.
function Start-DockerDesktop {
    if (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue) {
        Write-Host '  Docker Desktop is open; waiting for its engine...'
    } else {
        if (-not (Test-Path $DockerDesktopExe)) { throw "Docker Desktop isn't at $DockerDesktopExe. Start it yourself." }
        Write-Host '  Starting Docker Desktop...'
        if ($admin) { Start-Process explorer.exe -ArgumentList "`"$DockerDesktopExe`"" } else { Start-Process $DockerDesktopExe }
    }
    $deadline = (Get-Date).AddSeconds($DockerStartSeconds)
    while (-not (Test-Docker info --format '{{.ServerVersion}}')) {
        if ((Get-Date) -gt $deadline) { throw "Docker Desktop's engine didn't answer within $DockerStartSeconds seconds. Open Docker Desktop and look." }
        Start-Sleep -Seconds 5
    }
    Write-Host '  Docker Desktop is running.' -ForegroundColor Green
}

# For Add and Remove of a Docker runner: offers to start Docker Desktop when it is installed but not running.
function Assert-DockerUp {
    if ((Get-DockerEngine) -ne 'down') { Assert-Docker; return }
    if (-not (Ask 'Docker Desktop is not running. Start it now?')) { throw 'Docker runners need Docker Desktop running.' }
    Start-DockerDesktop
}

# The Docker half of recover: starts Docker Desktop when its engine isn't answering (from the menu, after asking),
# then runs LinuxRunners.ps1's recover over the runner containers. Nothing to do without Docker Desktop.
function Invoke-DockerRecover {
    $engine = Get-DockerEngine
    if ($engine -eq 'none') { return }
    Step 'Docker runners'
    if ($engine -eq 'down') {
        if (-not (Confirm-Fix 'Docker Desktop' 'not running, so its runner containers are down' 'Start Docker Desktop')) {
            Write-Host "  Docker Desktop left off: the Docker runners weren't checked." -ForegroundColor Yellow
            return
        }
        Start-DockerDesktop
        # The containers start with Docker (--restart unless-stopped); give them time to connect before checking them.
        Write-Host '  Waiting 30 seconds for the runner containers to connect...'
        Start-Sleep -Seconds 30
    }
    if ($Target) { Import-Target }
    Invoke-LinuxRecover
}

# "recover" for both kinds: the Windows-service runners, then the Docker runners. One failing doesn't stop the other.
function Invoke-AllRecover {
    $failed = @()
    Step 'Windows-service runners'
    try { Invoke-Recover } catch {
        Write-Host "Recover of the Windows-service runners failed: $($_.Exception.Message)" -ForegroundColor Red
        $failed += 'Windows-service'
    }
    try { Invoke-DockerRecover } catch {
        Write-Host "Recover of the Docker runners failed: $($_.Exception.Message)" -ForegroundColor Red
        $failed += 'Docker'
    }
    if ($failed.Count) { throw "Recover didn't finish for the $($failed -join ' and ') runners (see above)." }
}

# Add and Remove ask which kind of runner first.
function Read-Kind($verb) {
    $k = (Read-Host "$verb which kind? W) Windows service  D) Docker container (Linux)  [W]").Trim()
    if ($k -match '^[dD]') { return 'docker' }
    if ($k -and $k -notmatch '^[wW]') { throw "'$k' isn't W or D." }
    'windows'
}

function Add-AnyRunner {
    if ((Read-Kind 'Add') -eq 'windows') { Add-Runner; return }
    Assert-DockerUp
    Read-LinuxAdd
}

function Remove-AnyRunner {
    if ((Read-Kind 'Remove') -eq 'windows') { Remove-Runner; return }
    Assert-DockerUp
    Show-Status
    Remove-LinuxRunner (Read-Host 'Runner or container name').Trim()
}

. "$PSScriptRoot\lib\Watchdog.ps1"
. "$PSScriptRoot\lib\RecoverWindows.ps1"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Unattended) { Start-WatchdogLog 'windows' }
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'gh is not signed in. Run: gh auth login' -ForegroundColor Red
    if ($Unattended) { Stop-Transcript | Out-Null } elseif ($Command -eq 'menu') { Read-Host 'Press Enter to close' }
    exit 1
}

# Commands without the menu: they all need admin (services, scheduled task), and print errors instead of prompting.
if ($Command -ne 'menu') {
    $code = 0
    try {
        if (-not $admin) { throw "$Command needs admin rights: run it from an elevated PowerShell, or use Runners.cmd." }
        switch ($Command) {
            'recover' { Invoke-AllRecover }
            'watch' { Start-Watch $Interval { Invoke-AllRecover } }
            'install-watchdog' { Import-WindowsTarget; Install-Watchdog 'windows' $PSCommandPath $Target 'Highest' $Interval }
            'uninstall-watchdog' { Uninstall-Watchdog 'windows' }
        }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $code = 1
    }
    if ($Unattended) { Stop-Transcript | Out-Null }
    exit $code
}

if (-not $admin) { Write-Host 'Not running as administrator: listing works, but adding or removing a runner needs Runners.cmd (it asks for admin).' -ForegroundColor Yellow }

while ($true) {
    Write-Host ''
    Write-Host 'GitHub runners (Windows services and Docker): 1) List  2) Add  3) Remove  4) Clean up leftovers  5) Recover  6) Install watchdog  7) Remove watchdog  Q) Quit' -ForegroundColor Cyan
    $choice = Read-Host 'Choose'
    try {
        switch ($choice) {
            '1' { Show-Runners (Get-AllRunners) }
            '2' { Add-AnyRunner }
            '3' { Remove-AnyRunner }
            '4' { Clear-Leftovers }
            '5' {
                $script:Target = Select-Target 'repository and labels to re-register with'
                $script:Interactive = $true
                try { Invoke-AllRecover } finally { $script:Interactive = $false }
            }
            '6' { Read-WatchdogInstall 'windows' $PSCommandPath 'Highest' }
            '7' { Read-WatchdogRemove 'windows' }
            { $_ -match '^[qQ]?$' } { exit 0 }
        }
    } catch {
        Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    }
}
