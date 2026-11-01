# Adds the Microsoft Defender exclusions that keep self-hosted runner builds fast. Double-click
# "DefenderExclusions.cmd" to open the menu (it asks for admin rights, which Defender changes need).
#
# Real-time scanning of the folders a Gradle/Kotlin Multiplatform build and Docker Desktop churn through is a
# large part of why a heavy build runs slow enough to exhaust memory and wedge a runner; the watchdog in
# lib\Watchdog.ps1 recovers a wedge after it happens, these exclusions make it happen far less often. Every
# exclusion is listed in a variable below so you can read exactly what is added before you add it.
$ErrorActionPreference = 'Stop'

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($question) { (Read-Host "$question (y/N)") -match '^y' }

# Where the Windows runners install (one folder per repo, each with a _work build tree underneath).
$runnerRoot = 'C:\actions-runner'

# Folders a build and Docker Desktop read and write constantly. Excluding these is low risk: they hold caches,
# checkouts and virtual disks, not the files Defender most needs to watch.
$ExcludePaths = @(
    $runnerRoot                                   # runner installs + their _work checkouts and build output
    "$env:USERPROFILE\.gradle"                    # Gradle caches, wrapper dists, build cache
    "$env:USERPROFILE\.konan"                     # Kotlin/Native toolchain and caches
    "$env:USERPROFILE\.m2"                         # Maven local repository
    "$env:USERPROFILE\.android"                   # Android SDK caches
    "$env:LOCALAPPDATA\Docker"                    # Docker Desktop data, incl. the WSL2 data virtual disk
)

# Process exclusions skip scanning files these processes touch. A bigger speed-up than the paths, and a wider
# one: only sensible on a dedicated build box like this. Listed separately so you can add paths only if you
# would rather not exclude whole processes.
$ExcludeProcesses = @(
    'Runner.Listener.exe'                         # the runner agent
    'Runner.Worker.exe'                           # the per-job worker
    'java.exe'; 'javaw.exe'                        # Gradle, the Kotlin compiler, the daemon
    'dockerd.exe'; 'com.docker.backend.exe'        # Docker engine and backend
    'Docker Desktop.exe'                           # Docker Desktop
    'vmmem.exe'; 'vmmemWSL.exe'; 'wslservice.exe'  # the WSL2 VM that hosts the Linux containers
)

function Test-Defender {
    try { Get-MpPreference | Out-Null } catch {
        throw "Can't read Microsoft Defender settings here. Defender may be off or a third-party antivirus is managing this machine; add its exclusions in that product instead."
    }
}

# What this script would manage, that Defender already has.
function Get-Current {
    $p = Get-MpPreference
    [pscustomobject]@{ Paths = @($p.ExclusionPath); Processes = @($p.ExclusionProcess) }
}

function Show-Current {
    Step 'Exclusions this script manages, and whether Defender already has them'
    $cur = Get-Current
    Write-Host 'Paths:'
    foreach ($path in $ExcludePaths) {
        $has = $cur.Paths -contains $path
        Write-Host ('  [{0}] {1}' -f $(if ($has) { 'x' } else { ' ' }), $path) -ForegroundColor $(if ($has) { 'Gray' } else { 'Yellow' })
    }
    Write-Host 'Processes:'
    foreach ($proc in $ExcludeProcesses) {
        $has = $cur.Processes -contains $proc
        Write-Host ('  [{0}] {1}' -f $(if ($has) { 'x' } else { ' ' }), $proc) -ForegroundColor $(if ($has) { 'Gray' } else { 'Yellow' })
    }
    Write-Host ''
}

# Add-MpPreference is additive and ignores a duplicate, so this is safe to run again.
function Add-Exclusions($withProcesses) {
    Step 'Adding path exclusions'
    foreach ($path in $ExcludePaths) {
        Add-MpPreference -ExclusionPath $path
        Write-Host "  added $path" -ForegroundColor Green
    }
    if ($withProcesses) {
        Step 'Adding process exclusions'
        foreach ($proc in $ExcludeProcesses) {
            Add-MpPreference -ExclusionProcess $proc
            Write-Host "  added $proc" -ForegroundColor Green
        }
    } else {
        Write-Host ''
        Write-Host 'Skipped process exclusions. Paths alone already cover most of the build I/O.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Done. New builds on this machine will not be scanned in those folders.' -ForegroundColor Green
}

# Removes only what this script adds, leaving any other exclusion you set by hand untouched.
function Remove-Exclusions {
    Step 'Removing the exclusions this script manages'
    $cur = Get-Current
    foreach ($path in $ExcludePaths) {
        if ($cur.Paths -contains $path) { Remove-MpPreference -ExclusionPath $path; Write-Host "  removed $path" -ForegroundColor Green }
    }
    foreach ($proc in $ExcludeProcesses) {
        if ($cur.Processes -contains $proc) { Remove-MpPreference -ExclusionProcess $proc; Write-Host "  removed $proc" -ForegroundColor Green }
    }
    Write-Host ''
    Write-Host 'Removed. Only exclusions this script added were touched.' -ForegroundColor Green
}

function Show-Menu {
    Write-Host ''
    Write-Host 'Defender exclusions for self-hosted runners' -ForegroundColor Cyan
    Write-Host '  1. Add exclusions (paths + build/Docker processes)'
    Write-Host '  2. Add exclusions (paths only)'
    Write-Host '  3. Show current exclusions'
    Write-Host '  4. Remove the exclusions this script manages'
    Write-Host '  0. Quit'
    Write-Host ''
    (Read-Host 'Choice').Trim()
}

Test-Defender
while ($true) {
    switch (Show-Menu) {
        '1' { if (Ask 'Add path and process exclusions for this build machine?') { Add-Exclusions $true } }
        '2' { if (Ask 'Add path exclusions only?') { Add-Exclusions $false } }
        '3' { Show-Current }
        '4' { if (Ask 'Remove the exclusions this script added?') { Remove-Exclusions } }
        '0' { break }
        default { Write-Host 'Pick 0-4.' -ForegroundColor Yellow }
    }
}
