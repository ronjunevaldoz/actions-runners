# Manages the Linux self-hosted runners on this computer: Docker Desktop containers built from GitHub's runner image.
# Double-click "LinuxRunners.cmd" for the menu, or run: .\LinuxRunners.ps1 add|remove|status|adopt|recover ... (see README).
# Runners.cmd is the main menu, for these and the Windows-service runners; this script and its menu still work.
# The functions live in lib\Linux.ps1, which Runners.ps1 loads too.
# Runner names are <host>-linux-<n> (host = this computer's name, lowercased; -Prefix overrides it).
# Each runner is a container and a volume (the runner's files and work folder), both named gh-runner-<runner name>.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('menu', 'add', 'remove', 'status', 'adopt', 'recover', 'watch', 'install-watchdog', 'uninstall-watchdog')][string]$Command = 'menu',
    # A number (2 -> <host>-linux-2) or a runner name. For remove: also a container name. For adopt: a container name.
    [Parameter(Position = 1)][string]$Runner,
    [string]$Repo,     # owner/name, for a repository runner
    [string]$Org,      # organization name, for an organization runner (instead of -Repo)
    [string]$Target,   # reads defaults from targets\<Target>.local.json (git-ignored) or targets\<Target>.json
    [string]$Prefix = [Environment]::MachineName,
    [string]$Labels = 'docker',
    # Per-container limits; '' or 0 means no limit. Gradle/KMP builds get OOM-killed (and wedge the runner) under
    # about 8 GB; heavy ones want 16g or 0. Containers a job starts on the host's Docker engine (services,
    # docker build) are siblings and don't count against these.
    [string]$Memory = '8g',
    [double]$Cpus = 2,
    # Read the registration token from the clipboard instead of typing it. The clipboard is cleared afterwards.
    [switch]$FromClipboard,
    # Take over a name GitHub already has registered (e.g. after rebuilding a runner). Off by default so adding
    # can't silently steal the registration of a runner that is still running somewhere.
    [switch]$Replace,
    # Used by the watchdog task: the recover report goes to its log, and offline runners get a grace period.
    [switch]$Unattended,
    [int]$Interval = 5   # minutes between checks, for watch and install-watchdog
)
$ErrorActionPreference = 'Stop'
$Bound = $PSBoundParameters   # what the caller passed; a target file never overrides these

. "$PSScriptRoot\lib\Watchdog.ps1"
. "$PSScriptRoot\lib\Linux.ps1"
. "$PSScriptRoot\lib\RecoverLinux.ps1"

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($question) { (Read-Host "$question (y/N)") -match '^y' }

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host 'Linux Docker runners: 1) Status  2) Add  3) Remove  4) Adopt existing container  5) Recover  6) Install watchdog  7) Remove watchdog  Q) Quit' -ForegroundColor Cyan
        $choice = Read-Host 'Choose'
        try {
            switch ($choice) {
                '1' { Show-Status }
                '2' { Read-LinuxAdd }
                '3' { Show-Status; Remove-LinuxRunner (Read-Host 'Runner or container name').Trim() }
                '4' { Show-Status; Invoke-Adopt (Read-Host 'Container name to adopt').Trim() }
                '5' {
                    $t = Select-Target 'repository and labels to re-register with'
                    if ($t) { $script:Target = $t; Import-Target }
                    $script:Interactive = $true
                    try { Invoke-LinuxRecover } finally { $script:Interactive = $false }
                }
                '6' { Read-WatchdogInstall 'linux' $PSCommandPath 'Limited' }
                '7' { Read-WatchdogRemove 'linux' }
                { $_ -match '^[qQ]?$' } { return }
            }
        } catch {
            Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

$code = 0
try {
    if ($Unattended) { Start-WatchdogLog 'linux' }
    Assert-Docker
    Import-Target
    switch ($Command) {
        'menu' { Show-Menu }
        'add' { Add-LinuxRunner $Runner }
        'remove' { Remove-LinuxRunner $Runner }
        'status' { Show-Status }
        'adopt' { Invoke-Adopt $Runner }
        'recover' { Invoke-LinuxRecover }
        'watch' { Start-Watch $Interval { Invoke-LinuxRecover } }
        'install-watchdog' { Install-Watchdog 'linux' $PSCommandPath $Target 'Limited' $Interval }
        'uninstall-watchdog' { Uninstall-Watchdog 'linux' }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Command -eq 'menu') { Read-Host 'Press Enter to close' }
    $code = 1
}
if ($Unattended) { Stop-Transcript | Out-Null }
exit $code
