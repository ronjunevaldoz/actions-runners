# Manages the self-hosted GitHub Actions runners on this computer. Double-click "Runners.cmd" to open the menu.
# Runners live in C:\actions-runner\<name>, one per repository, each installed as a Windows service.
$ErrorActionPreference = 'Stop'
$root = 'C:\actions-runner'
# Older hand-made installs registered straight into these folders; scanned so leftovers there get cleaned up too.
$legacy = @($root, "$env:USERPROFILE\actions-runner")

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

function Show-Runners($rows) {
    Write-Host ''
    $i = 0
    foreach ($r in $rows) {
        $i++
        $svc = if ($r.Local -and $r.Local.Service) { $r.Local.Service.Status } elseif ($r.Local) { 'no service' } else { '-' }
        $folder = if ($r.Local) { $r.Local.Folder } else { '' }
        $color = if ($r.State -in 'online', 'busy') { 'Gray' } else { 'Yellow' }
        Write-Host ('{0,3}. {1,-26} {2,-22} {3,-24} {4,-10} {5}' -f $i, $r.Repo, $r.Name, $r.State, $svc, $folder) -ForegroundColor $color
    }
    if (-not $rows.Count) { Write-Host '  No runners on this computer.' }
    Write-Host ''
}

function Remove-Service($local) {
    if (-not $local.Service) { return }
    if ($local.Service.Status -ne 'Stopped') { Stop-Service $local.Service.Name -Force }
    & sc.exe delete $local.Service.Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't delete service $($local.Service.Name)." }
}

# Undoes a registration in a folder. config.cmd remove hangs when GitHub already deleted the runner,
# so in that case the registration files are deleted directly.
function Clear-Registration($local) {
    Remove-Service $local
    $repo = Resolve-Repo $local.Repo
    if (Get-Remote $repo | Where-Object { $_.id -eq $local.Id }) {
        $token = Invoke-Gh api -X POST "repos/$repo/actions/runners/remove-token" --jq .token
        Push-Location $local.Folder
        try { & .\config.cmd remove --token $token } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw 'config.cmd remove failed.' }
    } else {
        foreach ($f in '.runner', '.runner_migrated', '.credentials', '.credentials_rsaparams', '.credentials_migrated', '.service') {
            $path = Join-Path $local.Folder $f
            if (Test-Path $path) { Remove-Item $path -Force }
        }
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

function Add-Runner {
    $repo = (Read-Host 'Repository (owner/name)').Trim()
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "'$repo' isn't owner/name." }
    $repo = Resolve-Repo $repo
    $taken = @((Get-Remote $repo).name)
    # The suggested name is the first free one: <repo>-runner, then <repo>-runner-2, -3, ... skipping names GitHub has
    # registered and folders already in $root, so taking the default adds a runner instead of replacing one.
    $base = ($repo -split '/')[1] + '-runner'
    $folders = @((Get-ChildItem $root -Directory -ErrorAction SilentlyContinue).Name)
    $default = $base
    for ($n = 2; ($taken -contains $default) -or ($folders -contains $default); $n++) { $default = "$base-$n" }
    $name = (Read-Host "Runner name [$default]").Trim()
    if (-not $name) { $name = $default }
    $labels = (Read-Host 'Extra labels, comma-separated (optional, e.g. golearn)').Trim() -replace '\s', ''
    $replace = $false
    if ($taken -contains $name) {
        if (-not (Ask "$repo already has a runner named $name. Replace it?")) { return }
        $replace = $true
    }

    # Reuse this runner's old folder if there is one, else C:\actions-runner\<name>.
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
    $runsOn = @('self-hosted', 'Windows') + @($labels -split ',' | Where-Object { $_ })
    Write-Host "Done. Workflows in $repo can use: runs-on: [$($runsOn -join ', ')]" -ForegroundColor Green
}

function Remove-Runner {
    $rows = Get-Runners
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
    $stale = @(Get-Runners | Where-Object { $_.State -in 'gone from GitHub', 'offline, not on this PC' })
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

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Write-Host 'gh is not signed in. Run: gh auth login' -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
if (-not $admin) { Write-Host 'Not running as administrator: listing works, but adding or removing a runner needs Runners.cmd (it asks for admin).' -ForegroundColor Yellow }

while ($true) {
    Write-Host ''
    Write-Host 'GitHub runners: 1) List  2) Add  3) Remove  4) Clean up leftovers  Q) Quit' -ForegroundColor Cyan
    $choice = Read-Host 'Choose'
    try {
        switch ($choice) {
            '1' { Show-Runners (Get-Runners) }
            '2' { Add-Runner }
            '3' { Remove-Runner }
            '4' { Clear-Leftovers }
            { $_ -match '^[qQ]?$' } { exit 0 }
        }
    } catch {
        Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    }
}
