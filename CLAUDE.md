# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Run the tool (from the project root):

```powershell
.\program-update-all.cmd            # interactive checklist of available updates
.\program-update-all.cmd -List      # print candidates, do not update
.\program-update-all.cmd -Inventory # list installed apps + global npm CLIs
.\program-update-all.cmd -Doctor    # provider diagnostics (Installed / Starts)
.\program-update-all.cmd -DryRun    # show what would run, execute nothing
.\program-update-all.cmd -All       # preselect every candidate
.\program-update-all.cmd -SkipDrivers
.\program-update-all.cmd -Yes       # skip the final confirmation prompt
```

Run the test suite:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

The runner has no name filter. To exercise a single case, either temporarily comment out the other `It` blocks, or import the module and call the function directly:

```powershell
Import-Module .\src\ProgramUpdateAll.psm1 -Force
ConvertFrom-WingetUpgradeTable -Text $sample
```

Install the short `update-all` command (creates a shim in `%LOCALAPPDATA%\Microsoft\WindowsApps`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-command.ps1
```

## Architecture

All logic lives in one module, [src/ProgramUpdateAll.psm1](src/ProgramUpdateAll.psm1) (~1690 lines). `program-update-all.cmd`, `program-update-all.ps1`, and `update-all.cmd` are thin wrappers that import the module and call `Invoke-ProgramUpdateAll`.

**Central data flow:** each provider is scanned by a `Get-*UpdateCandidates` function → results are normalized into a single shape via `New-UpdateCandidate` (`Provider/Category/Name/Id/InstalledVersion/AvailableVersion/UpdateCommand/UpdateArguments/RequiresAdmin/Metadata`) → `Invoke-ChecklistMenu` renders the interactive checklist → `Invoke-UpdateCandidate` dispatches execution by `Provider`. `Get-ProgramUpdateCandidates` is the aggregator that fans out to every provider and concatenates the candidates.

**Parse/execute split (the key to testability):** the pure `ConvertFrom-*` parsers (winget table, npm `outdated` JSON, choco, scoop, electron `app-update.yml`, GitHub release JSON, `git ls-remote`, uninstall registry entries) take text/objects in and return candidates — they call no external commands, and they are what the unit tests cover. The `Get-*UpdateCandidates` scanners are thin: `Test-CommandAvailable` guard → `Invoke-NativeText` → parser. Keep new logic in a pure parser so it stays testable.

**`Invoke-NativeText`** is the single entry point for invoking external tools. It uses `ProcessStartInfo` with UTF-8 stdout/stderr instead of a PowerShell pipeline — a direct pipe produces mojibake on localized output. There are tests guarding UTF-8 output and localized/mojibake winget tables, so route all external calls through this function.

**Privileges:** admin-only candidates (`RequiresAdmin`, e.g. drivers and chocolatey) are filtered out by `Get-PrivilegeBlockedUpdateCandidates` before running in a non-elevated session. They are not attempted one-by-one — they are shown separately with a prompt to re-run from an elevated terminal.

**Special dispatchers** inside `Invoke-UpdateCandidate`:
- `windows-update-driver` — Windows Update COM API (`Microsoft.Update.Session`), requires elevation.
- `github-electron` — scans `%LOCALAPPDATA%\Programs\*\resources\app-update.yml`, checks GitHub Releases, downloads the newer `.exe` asset to a temp dir and runs it.
- `local-git-app` — `git pull --ff-only` + `pnpm install`; skipped when the repo has local changes (`Test-LocalGitRepoHasChanges`) to avoid clobbering work in progress.

**Adding a provider:** follow the existing pattern — a pure `ConvertFrom-*` parser (with an `It` test) + a `Get-*UpdateCandidates` scanner + registration in `Get-ProgramUpdateCandidates`, and add any public function to `Export-ModuleMember` at the bottom of the module.

## Working principles

- **Surgical changes.** The module is large and stylistically uniform (`Set-StrictMode -Version Latest`, backtick line continuations, `[pscustomobject]` outputs). Touch only what the task needs; don't refactor adjacent code or reformat untouched lines.
- **Simplicity first.** Add the minimum code that solves the task. Don't introduce configurability or error handling for impossible cases beyond what the provider pattern already does.
- **Verify first.** Express new parsing logic as a pure `ConvertFrom-*` function and cover it with an `It` + `Assert-Equal` test in [tests/run-tests.ps1](tests/run-tests.ps1). Run the full suite before and after.
- **Surface uncertainty.** When a new tool's output format or its admin requirements are ambiguous, ask rather than guessing silently.
