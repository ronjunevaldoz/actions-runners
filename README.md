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

Or double-click **`LinuxRunners.cmd`** for a menu: status, add, remove, adopt.

| Command | What it does |
| --- | --- |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Memory 6g -Cpus 4` | Per-container limits. Default `4g` and `2` suit one Gradle build; `0` means no limit. |
| `.\LinuxRunners.ps1 add -Repo my-org/my-app -Replace` | Takes over a name GitHub already has. Off by default so a live runner isn't hijacked. |
| `.\LinuxRunners.ps1 status` | Lists runner containers: state, limits and volume. Hand-made ones show as `(not adopted)`. |
| `.\LinuxRunners.ps1 remove <host>-linux-2` | Deletes the container and its volume, then prints the GitHub page where you delete the registration. |
| `.\LinuxRunners.ps1 adopt <container>` | Brings a hand-made runner container under management (see below). |

**Targets (optional).** To avoid retyping, save a target as `targets\<name>.local.json` (git-ignored, so your real
repositories stay off GitHub) and use `-Target <name>`. Start from `targets\example.json`; it takes `repo` or
`org`, `prefix`, `labels`, `memory` and `cpus`. Values on the command line win over the file.

How it works:

- The token is only read with a hidden prompt or from the clipboard, never as an argument. It goes in on stdin of
  a one-off `docker run --rm` that runs `config.sh` against the runner's volume. The long-running container only
  runs `run.sh`, so neither its command line nor its environment holds the token. Check with
  `docker inspect gh-runner-<runner name> --format '{{json .Config.Env}}'`: no `RUNNER_TOKEN`.
- The container restarts with Docker Desktop (`--restart unless-stopped`) and keeps logs to 3 x 10 MB.
- The image version is set once, at the top of `LinuxRunners.ps1` (`$Image`), and only matters for new runners:
  a runner updates itself inside its volume.
- Memory and CPU limits cover the runner container only. Containers a job starts on the host engine (services,
  `docker build`) are siblings and count against Docker Desktop's own limit (Settings > Resources).

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
