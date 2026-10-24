# Self-hosted GitHub Actions runners

Scripts for the self-hosted runners on this Windows 11 computer: add, list, re-register and remove them, and
install or uninstall their Windows services. Each runner serves one repository.

This repo holds **only scripts and `runners.json`**. The runners themselves (binaries, `_work`, `.runner`,
`.credentials`) live in `C:\actions-runner\<name>` (set `RUNNER_ROOT` to use another folder) and never go in git.
Registration and remove tokens are fetched from `gh` when a script needs one and are never written to disk.

## Requirements

- `gh` signed in with the `repo` scope (`gh auth status`) and admin access to each repository.
- An elevated PowerShell (Run as administrator) for anything that touches a service.
- Repository runners only. Organization runners would need `gh auth refresh -s admin:org` and other API paths.

## Commands

| Task | Command |
| --- | --- |
| See every runner, here and on GitHub, and what's wrong with each | `.\Get-Runners.ps1` |
| Add a runner as a service | `.\Add-Runner.ps1 -Repo owner/name [-Name x] [-Labels a,b]` |
| Add one by double-click | `Add GitHub runner.cmd` (asks for admin, then the repository) |
| Add one without a service (run it with `run.cmd`) | `.\Add-Runner.ps1 -Repo owner/name -NoService` |
| Re-register (new token, labels, or after GitHub forgot it) | `.\Add-Runner.ps1 -Repo owner/name -Name x -Replace` |
| Remove a runner here (service + `config.cmd remove`) | `.\Remove-Runner.ps1 -Name x [-DeleteFolder]` |
| Delete a runner on GitHub that has no folder here | `.\Remove-Runner.ps1 -Name x -Repo owner/name` |
| Delete dead runners in bulk | `.\Remove-StaleRunners.ps1 -WhatIf`, then without `-WhatIf` |
| Also clear local registrations GitHub forgot | `.\Remove-StaleRunners.ps1 -IncludeLocal [-DeleteFolder]` |
| Install / uninstall only the service | `.\Install-RunnerService.ps1 -Name x` / `.\Uninstall-RunnerService.ps1 -Name x` |

Everything that deletes something asks first; pass `-WhatIf` to see what it would do, or `-Confirm:$false` to skip
the questions. If PowerShell refuses to run the scripts, start it with `powershell -ExecutionPolicy Bypass`.

## What Get-Runners flags

| Problem | Meaning | Fix |
| --- | --- | --- |
| `stale-local` | A folder here is registered, but GitHub no longer has that runner. | `Remove-StaleRunners.ps1 -IncludeLocal`, or `Add-Runner.ps1 ... -Replace` to bring it back |
| `stale-remote` | Offline on GitHub and no folder here. It may be dead, or just on a computer that's off. | `Remove-StaleRunners.ps1` (confirm only the dead ones) |
| `no-service` | Registered here but not a service, so it only runs while `run.cmd` is open. | `Install-RunnerService.ps1 -Name x` |
| `not-inventory` | Works, but `runners.json` doesn't list it. | Re-add it, or add the entry by hand |
| `legacy-folder` | Registered outside `C:\actions-runner\<name>` (an old hand-made install). | Remove it and add it again |

## runners.json

The list of runners this computer is meant to have: name, repository, extra labels, folder. `Add-Runner.ps1` and
the remove scripts keep it up to date; commit the change after each one so the history shows when a runner came or
went. It holds no secrets.

## Using a runner from a workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, Windows]   # plus any -Labels you gave the runner
```

A runner registered with `-Labels android` is picked by `runs-on: [self-hosted, Windows, android]`.

## How the pieces fit

- `RunnerTools.psm1` holds the shared helpers: find local registrations (`.runner` files), list GitHub's runners,
  fetch tokens, download and checksum the latest runner zip into `C:\actions-runner\_packages`, edit `runners.json`.
- Services are named `actions.runner.<owner>-<repo>.<name>` and run as `NT AUTHORITY\NETWORK SERVICE`, the same as
  `config.cmd --runasservice` makes them. A renamed repository keeps its old name in the service name; that's fine.
- The runner updates itself; old versions pile up as `bin.<version>` and `externals.<version>` folders.
