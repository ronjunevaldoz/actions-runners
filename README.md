# Self-hosted GitHub Actions runners

Double-click **`Runners.cmd`**. Windows asks for admin rights once, then a menu offers:

1. **List** every runner on this computer and its state on GitHub (leftovers show in yellow).
2. **Add** a runner: asks for the repository, a name and optional labels, then registers it and installs it as a
   Windows service. Adding a name that already exists replaces it, which also re-registers a broken runner.
3. **Remove** a runner: pick it by number. It deletes the service and the registration, and optionally the folder.
4. **Clean up leftovers**: registrations GitHub has forgotten, offline runners with no folder here, and folders
   with nothing registered in them. Asks before each one.

Needs `gh` signed in (`gh auth login`) with admin access to the repositories.

Runners live in `C:\actions-runner\<name>`, never in this repo, so no credentials or tokens end up in git.
A workflow picks a runner with `runs-on: [self-hosted, Windows, <label>]`.
