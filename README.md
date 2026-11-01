# Self-hosted GitHub Actions runners

Double-click **`Runners.cmd`**. Windows asks for admin rights once, then a menu offers:

1. **List** every runner on this computer and its state on GitHub (leftovers show in yellow).
2. **Add** a runner: asks for the repository, a name and optional labels, then registers it and installs it as a
   Windows service. The suggested name is the next free `<host>-windows-<n>` (`<host>` is this computer's name,
   lowercased), so accepting it adds another runner. Typing a name that already exists replaces it, which also
   re-registers a broken runner.
3. **Remove** a runner: pick it by number. It deletes the service and the registration, and optionally the folder.
4. **Clean up leftovers**: registrations GitHub has forgotten, offline runners with no folder here, and folders
   with nothing registered in them. Asks before each one.
5. **Recover**: brings back runners that are stuck (see [Recover and the watchdog](#recover-and-the-watchdog)). Offers
   your saved targets, shows what it found for each runner and asks before fixing it (`a` = yes to all the rest).
6. **Install watchdog**: asks for a target and how often to check (default 5 minutes), confirms, then creates a
   scheduled task that runs Recover in the background, so a crashed runner comes back by itself.
7. **Remove watchdog**: shows the task and asks before removing it.

Needs `gh` signed in (`gh auth login`) with admin access to the repositories.

Runners live in `C:\actions-runner\<name>`, never in this repo, so no credentials or tokens end up in git.
A workflow picks a runner with `runs-on: [self-hosted, Windows, <label>]`.

## Linux Docker runners

Linux runners run as containers in Docker Desktop, from GitHub's runner image
(`ghcr.io/actions/actions-runner`), and use the host's Docker engine for jobs that need Docker. Start Docker Desktop
first; the script refuses to run without it. No admin rights needed.

- Runner names: `<host>-linux-<n>`, where `<host>` is this computer's name, lowercased. `-Prefix` changes the host
  part; giving a name instead of a number (`add my-runner ...`) sets the whole name.
- Container and volume: `gh-runner-<runner name>`. The volume holds the runner's files, registration and `_work`.
- Labels: `self-hosted, Linux, X64` plus `docker` by default, so a workflow picks one with
  `runs-on: [self-hosted, Linux, docker]`. Extra labels go in `-Labels docker,gradle`.

**Add a runner for a repository:**

1. On GitHub: the repository's Settings > Actions > Runners > New self-hosted runner. Copy the `--token` value from
   the Configure step (it expires after an hour). The script prints this link too.
2. In PowerShell, in this folder:

   ```powershell
   .\LinuxRunners.ps1 add -Repo my-org/my-app          # next free number: <host>-linux-1, -2, ...
   .\LinuxRunners.ps1 add 2 -Repo my-org/my-app -Prefix pc   # pc-linux-2
   .\LinuxRunners.ps1 add -Org my-org                  # organization runner
   ```

   Paste the token at the hidden prompt, or add `-FromClipboard` to read it from the clipboard (cleared afterwards).

Or double-click **`LinuxRunners.cmd`** for a menu: status, add, remove, adopt, recover, install / remove watchdog. Recover
and the watchdog prompt the same way as in `Runners.cmd`.

| Command | What it does |
| --- | --- |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Memory 16g -Cpus 4` | Per-container limits. Default `8g` and `2`; `0` means no limit. Under `8g` it warns (see [Memory](#memory)). |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Replace` | Takes over a name GitHub already has. Off by default so a live runner isn't hijacked. |
| `.\LinuxRunners.ps1 status` | Lists runner containers: state, limits and volume. Hand-made ones show as `(not adopted)`. |
| `.\LinuxRunners.ps1 remove <host>-linux-2` | Deletes the container and its volume, then prints the GitHub page where you delete the registration. |
| `.\LinuxRunners.ps1 adopt <container>` | Brings a hand-made runner container under management (see below). |
| `.\LinuxRunners.ps1 recover [-Target <name>]` | Checks every managed runner and fixes the stuck ones (see [Recover](#recover-and-the-watchdog)). |
| `.\LinuxRunners.ps1 watch [-Target <name>] [-Interval 5]` | Runs `recover` in this window every 5 minutes until Ctrl+C. |
| `.\LinuxRunners.ps1 install-watchdog [-Target <name>] [-Interval 5]` | Runs `recover` every 5 minutes while you're signed in. |
| `.\LinuxRunners.ps1 uninstall-watchdog` | Removes that scheduled task. |

**Targets (optional).** To avoid retyping, save a target as `targets\<name>.local.json` (git-ignored, so your real
repositories stay off GitHub) and use `-Target <name>`. Start from `targets\example.json`; it takes `repo` or
`org`, `prefix`, `labels`, `memory` and `cpus`. Values on the command line win over the file. `Runners.ps1` reads the
same files for `recover` (only `repo` and `labels`).

How it works:

- The token is only read with a hidden prompt or from the clipboard, never as an argument. It goes in on stdin of
  a one-off `docker run --rm` that runs `config.sh` against the runner's volume. The long-running container only
  runs `run.sh`, so neither its command line nor its environment holds the token. Check with
  `docker inspect gh-runner-<runner name> --format '{{json .Config.Env}}'`: no `RUNNER_TOKEN`.
- The container restarts with Docker Desktop and after a crash (`--restart unless-stopped`; `recover` puts the policy
  back if it was changed) and keeps logs to 3 x 10 MB.
- The image version is set once, at the top of `LinuxRunners.ps1` (`$Image`), and only matters for new runners:
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
.\Runners.ps1 recover                         # Windows runners, from an elevated PowerShell (or menu 5 in Runners.cmd)
.\LinuxRunners.ps1 recover -Target my-app      # Linux runners (or menu 5 in LinuxRunners.cmd)
```

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
is up and wedged. The watchdog is a scheduled task (Task Scheduler > `actions-runners`) that runs `recover` every
5 minutes:

```powershell
.\Runners.ps1 install-watchdog -Target my-app      # elevated; -Target and -Interval (minutes, default 5) optional
.\LinuxRunners.ps1 install-watchdog -Target my-app -Interval 10
.\Runners.ps1 uninstall-watchdog                   # and .\LinuxRunners.ps1 uninstall-watchdog
.\LinuxRunners.ps1 watch -Target my-app            # the same loop in this window, until Ctrl+C
```

Or menu 6 (install: asks for the target and interval, then confirms) and 7 (remove) in either `.cmd`. It runs as you, only while you're signed in: `gh` keeps its
login in your profile, and Docker Desktop only runs then too. A runner that is up but offline may just be updating
itself, so the watchdog restarts it only once it has seen it like that for 4 minutes (its next run); `recover` run
by hand acts at once. Reports go to `%LOCALAPPDATA%\actions-runners\windows-watchdog.log` and `linux-watchdog.log`
(rolled over at 1 MB).
