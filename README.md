# Self-hosted GitHub Actions runners

Double-click **`Runners.cmd`**: it is the one menu for every runner on this computer, both the Windows-service
runners and the [Linux runners in Docker Desktop](#linux-docker-runners). Windows asks for admin rights once, then
the menu offers:

1. **List** every runner on this computer, both kinds in one table, with its real state (problems show in yellow).
   A Windows runner shows its state on GitHub and its service. A Docker runner shows `Docker Desktop not running`,
   `container exited (exit 137, OOM-killed)` (or stopped, restarting, paused), `running, online`,
   `running, offline on GitHub` or `busy`.
2. **Add** a runner: asks which kind, **W**indows service or **D**ocker container.
   - Windows: asks for the repository, a name and optional labels, then registers it and installs it as a Windows
     service. The suggested name is the next free `<host>-windows-<n>` (`<host>` is this computer's name,
     lowercased), so accepting it adds another runner. Typing a name that already exists replaces it, which also
     re-registers a broken runner.
   - Docker: asks for a saved target or the repository, the runner number or name, labels, limits and the token,
     as described under [Linux Docker runners](#linux-docker-runners). Offers to start Docker Desktop if it isn't
     running.
3. **Remove** a runner: asks which kind. A Windows runner is picked by number; it deletes the service and the
   registration, and optionally the folder. A Docker runner is picked by name; it deletes the container and its
   volume, then prints the GitHub page where you delete the registration.
4. **Clean up leftovers**: registrations GitHub has forgotten, offline runners with no folder or container here,
   and folders with nothing registered in them. Asks before each one.
5. **Recover**: brings back runners of both kinds that are stuck, and starts Docker Desktop if it isn't running (see
   [Recover and the watchdog](#recover-and-the-watchdog)). Offers your saved targets, shows what it found for each
   runner and asks before fixing it (`a` = yes to all the rest).
6. **Install watchdog**: asks for a target and how often to check (default 5 minutes), confirms, then creates a
   scheduled task that runs Recover in the background, so a crashed runner, of either kind, comes back by itself.
7. **Remove watchdog**: shows the task and asks before removing it.

Needs `gh` signed in (`gh auth login`) with admin access to the repositories.

Runners live in `C:\actions-runner\<name>`, never in this repo, so no credentials or tokens end up in git.
A workflow picks a runner with `runs-on: [self-hosted, Windows, <label>]`.

## Which runner runs what

| Repository | Runners |
| --- | --- |
| `flyffawaken/flyffawaken` | Self-hosted only. Linux jobs (PR checks, server image, release, server deploy, play content) run on the Docker runner: label `docker`, picked through the repository variables `RUNNER_PR_LINUX` and `RUNNER_PR_LINUX_2` (both `docker`). GPU screenshot tests and the web deploy run on `[self-hosted, Windows, X64]`. Desktop installers are manual only (Actions > Desktop installers > Run workflow); the Windows and macOS installers use GitHub-hosted runners and need the organization's billing. |
| `awakekt/awake-plugins` | Its Windows self-hosted runner. |
| `awakekt/awake-studio` | Its Windows self-hosted runners. |
| `awakekt/awake` (Core) | GitHub-hosted and Blacksmith runners; no runners on this PC. |

Have Docker Desktop start when you sign in (Docker Desktop > Settings > General > Start Docker Desktop when you sign
in to your computer), so the Docker runner is up without anyone opening it. The watchdog starts it too.

## Linux Docker runners

Linux runners run as containers in Docker Desktop, from GitHub's runner image
(`ghcr.io/actions/actions-runner`), and use the host's Docker engine for jobs that need Docker. Manage them from
**`Runners.cmd`** like the Windows runners (List, Add, Remove, Recover and the watchdog all cover them).
`LinuxRunners.ps1` still works on its own, for the commands below and for scripts; it needs Docker Desktop running and
no admin rights.

- Runner names: `<host>-linux-<n>`, where `<host>` is this computer's name, lowercased. `-Prefix` changes the host
  part; giving a name instead of a number (`add my-runner ...`) sets the whole name.
- Container and volume: `gh-runner-<runner name>`. The volume holds the runner's files, registration and `_work`.
- Labels: `self-hosted, Linux, X64` plus `docker` by default, so a workflow picks one with
  `runs-on: [self-hosted, Linux, docker]`. Extra labels go in `-Labels docker,gradle`.

**Add a runner for a repository** (or **Add** > **D** in `Runners.cmd`, which asks the same questions):

1. On GitHub: the repository's Settings > Actions > Runners > New self-hosted runner. Copy the `--token` value from
   the Configure step (it expires after an hour). The script prints this link too.
2. In PowerShell, in this folder:

   ```powershell
   .\LinuxRunners.ps1 add -Repo my-org/my-app          # next free number: <host>-linux-1, -2, ...
   .\LinuxRunners.ps1 add 2 -Repo my-org/my-app -Prefix pc   # pc-linux-2
   .\LinuxRunners.ps1 add -Org my-org                  # organization runner
   ```

   Paste the token at the hidden prompt, or add `-FromClipboard` to read it from the clipboard (cleared afterwards).

`LinuxRunners.cmd` still opens its own Docker-only menu (status, add, remove, adopt, recover, install / remove
watchdog), after a line saying that `Runners.cmd` is the main menu. Adopting a hand-made container is only there, or
`.\LinuxRunners.ps1 adopt`.

| Command | What it does |
| --- | --- |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Memory 16g -Cpus 4` | Per-container limits. Default `8g` and `2`; `0` means no limit. Under `8g` it warns (see [Memory](#memory)). |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Replace` | Takes over a name GitHub already has. Off by default so a live runner isn't hijacked. |
| `.\LinuxRunners.ps1 status` | Lists runner containers: state, limits and volume. Hand-made ones show as `(not adopted)`. |
| `.\LinuxRunners.ps1 remove <host>-linux-2` | Deletes the container and its volume, then prints the GitHub page where you delete the registration. |
| `.\LinuxRunners.ps1 adopt <container>` | Brings a hand-made runner container under management (see below). |
| `.\LinuxRunners.ps1 recover [-Target <name>]` | Checks every managed runner and fixes the stuck ones (see [Recover](#recover-and-the-watchdog)). |
| `.\LinuxRunners.ps1 watch [-Target <name>] [-Interval 5]` | Runs `recover` in this window every 5 minutes until Ctrl+C. |
| `.\LinuxRunners.ps1 install-watchdog [-Target <name>] [-Interval 5]` | A Docker-only watchdog. Refused while the `Runners.cmd` watchdog is installed, which already covers Docker runners. |
| `.\LinuxRunners.ps1 uninstall-watchdog` | Removes that scheduled task. |

**Targets (optional).** To avoid retyping, save a target as `targets\<name>.local.json` (git-ignored, so your real
repositories stay off GitHub) and use `-Target <name>`. Start from `targets\example.json`; it takes `repo` or
`org`, `prefix`, `labels`, `memory` and `cpus`. Values on the command line win over the file. `Runners.ps1` reads the
same files for `recover`: only `repo` and `labels` for the Windows runners, all of it for the Docker runners.

How it works:

- The token is only read with a hidden prompt or from the clipboard, never as an argument. It goes in on stdin of
  a one-off `docker run --rm` that runs `config.sh` against the runner's volume. The long-running container only
  runs `run.sh`, so neither its command line nor its environment holds the token. Check with
  `docker inspect gh-runner-<runner name> --format '{{json .Config.Env}}'`: no `RUNNER_TOKEN`.
- The container restarts with Docker Desktop and after a crash (`--restart unless-stopped`; `recover` puts the policy
  back if it was changed) and keeps logs to 3 x 10 MB.
- The image version is set once, at the top of `lib\Linux.ps1` (`$Image`), and only matters for new runners:
  a runner updates itself inside its volume.
- Memory and CPU limits cover the runner container only. Containers a job starts on the host engine (services,
  `docker build`) are siblings and count against Docker Desktop's own limit (Settings > Resources).

<a id="memory"></a>
**Memory.** The default limit is `8g`. A Gradle or Kotlin Multiplatform build under a smaller limit gets OOM-killed,
and the runner can be left up but offline, blocking CI until someone restarts it. Heavy builds want `-Memory 16g`, or
`-Memory 0` for no limit. Adding a runner under `8g` prints a warning but keeps the value you gave. Raise an existing
runner's limit without recreating it: `docker update --memory 16g --memory-swap 32g gh-runner-<runner name>`.
The containers share Docker Desktop's own memory (Settings > Resources, or `.wslconfig` with WSL 2), so keep that
above the sum of the limits.

**Existing runners keep their names.** Nothing is renamed or re-registered; only new runners get the generic names.

- Windows runners added before the naming change (`<repo>-runner`, `<repo>-runner-2`, ...) stay as they are in
  `C:\actions-runner\<name>`; the menu lists and removes them as before.
- A hand-made Linux container (for example one started with `docker run ... --name <old-container>` and
  registered as `pc-linux-docker-1`) shows in `status` as `(not adopted)`. `.\LinuxRunners.ps1 adopt
  <old-container>` reads the registration from its volume and recreates the container with the same name, volume
  and registration, adding the management label and the limits. No token needed.
- To keep the old Linux numbering for a new runner, name it explicitly: `.\LinuxRunners.ps1 add pc-linux-docker-2
  -Repo my-org/my-app` (container `gh-runner-pc-linux-docker-2`).

**Security.** A container runner mounts `/var/run/docker.sock`, so any job it runs controls the host's Docker
engine, which amounts to admin on this PC. Only register it with your own private repositories, never a public
repository where pull requests from forks can run workflows.

## Recover and the watchdog

A runner that crashed, got OOM-killed or lost its connection stays offline and CI waits on it. `recover` checks
every runner this computer manages and fixes the stuck ones. The menus (item 5) are the main way in: pick a saved
target, see what each stuck runner has, and answer y / N / a (all) before each fix. The commands below do the same
without asking, for scripts. It is safe to run anytime: healthy and busy runners are
left alone, and runners it doesn't manage (other computers, `(not adopted)` containers) are never touched.

```powershell
.\Runners.ps1 recover                         # both kinds, from an elevated PowerShell (or menu 5 in Runners.cmd)
.\LinuxRunners.ps1 recover -Target my-app      # Docker runners only (or menu 5 in LinuxRunners.cmd)
```

`Runners.ps1 recover` checks the Windows-service runners first, then the Docker runners. If Docker Desktop is
installed but not running, it starts it (`%ProgramFiles%\Docker\Docker\Docker Desktop.exe`, as you, not as admin),
waits up to 3 minutes for `docker info` to answer and 30 seconds for the containers to connect, then recovers them.
From the menu it asks before starting Docker Desktop. `LinuxRunners.ps1 recover` doesn't start Docker Desktop.

| Found | Windows runner | Linux runner |
| --- | --- | --- |
| Healthy: online or busy on GitHub, host up | nothing | nothing |
| Host down: service stopped / container exited, OOM-killed, stuck restarting | restarts the service | `docker start` (or `docker restart`) |
| Host up but offline on GitHub, or idle while jobs for its labels have been queued for 10 minutes | restarts the service | `docker restart` |
| Deregistered: still here, but GitHub deleted it (for example after 14 days offline) | re-registers it under the same name, like **Add** with replace | re-registers it in its own volume (same container, same `_work`) with `--replace` |
| Registered on GitHub with this computer's naming, but missing here | reports it only: it may have been removed on purpose | reports it only (needs `-Target` or `-Repo`) |

It prints a before / action / after table, waiting 30 seconds after fixing something to show the final state.
Re-registering takes a token from `gh` (signed in, admin on the repository) and keeps the runner's labels from
GitHub; for a runner GitHub already deleted it uses the target's `labels` (Windows: only when the target's `repo` is
the runner's) or the default (`docker` for Linux). `recover` also makes Windows restart a crashed runner service by
itself (service recovery: after a minute, up to three times a day), the counterpart of Docker's restart policy.

**Watchdog.** Docker's restart policy and the service recovery bring back a process that died, but not a runner that
is up and wedged, nor Docker Desktop if it was closed. The watchdog is one scheduled task (Task Scheduler >
`actions-runners` > `windows-recover`) that runs `Runners.ps1 recover` every 5 minutes, so it covers both kinds and
starts Docker Desktop when it isn't running:

```powershell
.\Runners.ps1 install-watchdog -Target my-app      # elevated; -Target and -Interval (minutes, default 5) optional
.\Runners.ps1 uninstall-watchdog
.\Runners.ps1 watch -Target my-app                 # the same loop in this window, until Ctrl+C
```

Or menu 6 (install: asks for the target and interval, then confirms) and 7 (remove) in `Runners.cmd`. Installing it
removes the Docker-only task that `LinuxRunners.ps1 install-watchdog` used to create (`linux-recover`), so the two
don't both fix the same containers; while it is installed, `LinuxRunners.ps1` refuses to add that task again. It runs
as you, only while you're signed in: `gh` keeps its login in your profile, and Docker Desktop only runs then too. A runner that is up but offline may just be updating
itself, so the watchdog restarts it only once it has seen it like that for 4 minutes (its next run); `recover` run
by hand acts at once. Reports, for both kinds, go to `%LOCALAPPDATA%\actions-runners\windows-watchdog.log` (rolled over
at 1 MB; a Docker-only watchdog wrote to `linux-watchdog.log`).

## Keeping builds fast (Defender exclusions)

Microsoft Defender scans every file a build reads and writes. On a dedicated build machine that means it scans the
runner's checkouts, the Gradle and Kotlin/Native caches and Docker Desktop's virtual disks on every build, which
slows a heavy Gradle or Kotlin Multiplatform build enough that it can exhaust memory and leave a runner wedged (the
same failure [Memory](#memory) and the [watchdog](#recover-and-the-watchdog) deal with after the fact). Excluding
those folders makes it happen far less often.

Double-click **`DefenderExclusions.cmd`** (it asks for admin rights once, which Defender changes need) for a menu:

1. **Add exclusions (paths + build/Docker processes)** — the folders below, plus skipping the runner, Java and
   Docker processes. The bigger speed-up, and only sensible on a box dedicated to builds.
2. **Add exclusions (paths only)** — the folders alone, which already cover most of the build I/O.
3. **Show current exclusions** — each entry this script manages and whether Defender already has it.
4. **Remove the exclusions this script manages** — leaves any exclusion you set by hand untouched.

The exact paths and processes are listed in variables at the top of `DefenderExclusions.ps1`, so you can read what
will be added before adding it. Paths: `C:\actions-runner`, and under your profile `.gradle`, `.konan`, `.m2`,
`.android`, plus `%LOCALAPPDATA%\Docker`. Adding is safe to repeat — Defender ignores a duplicate.

> **Trade-off.** An exclusion tells Defender not to scan there, so keep these folders to build work only, and only
> register runners with your own private repositories (as the Linux [Security](#linux-docker-runners) note already
> says). The paths-only option is the conservative choice if you would rather not exclude whole processes.
