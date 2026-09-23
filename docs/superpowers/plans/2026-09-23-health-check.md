# Health Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Daily automatic health check of every installed program (GUI, CLI, AI agents) with slowdown detection, a report file, and a Windows toast on problems.

**Architecture:** New pillar `src/Health.ps1`, dot-sourced by `ProgramUpdateAll.psm1`. Pure functions (target building, status resolution, verdict, formatting) carry the logic and are unit-tested in `tests/run-tests.ps1`; thin scanners touch registry/files/processes/Task Scheduler and are not unit-tested. `Invoke-NativeText` gains a timeout.

**Tech Stack:** PowerShell 7 (pwsh), .NET `System.Diagnostics.Process`, Windows PowerShell 5.1 only for the WinRT toast, Task Scheduler cmdlets. No external modules.

**Spec:** `docs/superpowers/specs/2026-09-23-health-check-design.md`

## Global Constraints

- `Set-StrictMode -Version Latest` is on for the module; access optional properties via `PSObject.Properties.Name -contains`.
- Tests first: every new pure function gets a failing `It` block in `tests/run-tests.ps1` before its implementation. Run the full suite: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1` (must end with `N test(s) passed.`).
- All external calls go through `Invoke-NativeText`.
- Agent PONG prompt: `Reply with the single word PONG`. Agent timeout 180 s, CLI timeout 15 s.
- Slow = `DurationSeconds > 2 × median(last 7 OK runs)` AND `> 30`; needs ≥ 3 OK runs of history.
- Data dir: `%LOCALAPPDATA%\pc-keeper\health`; history `<yyyy-MM-dd>.json`, kept 30 days; `latest.txt`.
- Scheduled task name `PcKeeperHealthCheck`; action runs through `C:\Windows\System32\conhost.exe --headless`.
- UI strings in English (matches the rest of the module).

---

### Task 1: Timeout for Invoke-NativeText

**Files:**
- Modify: `src/Common.ps1:38-77` (`Invoke-NativeText`)
- Test: `tests/run-tests.ps1` (after the utf8 native command test)

**Interfaces:**
- Produces: `Invoke-NativeText -FilePath <string> [-Arguments <string[]>] [-TimeoutSeconds <int>] [-WorkingDirectory <string>]` → `{ ExitCode; StdOut; StdErr; Text; TimedOut [bool]; DurationSeconds [double] }`. With `TimeoutSeconds > 0` stdin is closed and the whole process tree is killed on timeout (`ExitCode = $null`).

- [ ] **Step 1: Write the failing tests**

```powershell
It 'kills a native command that exceeds its timeout' {
    $result = Invoke-NativeText -FilePath 'pwsh' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 2

    Assert-Equal $result.TimedOut $true 'timed out flag'
    Assert-Equal $result.ExitCode $null 'no exit code after timeout'
    Assert-Equal ($result.DurationSeconds -lt 15) $true 'returned soon after the timeout'
}

It 'reports duration and no timeout for a quick native command' {
    $result = Invoke-NativeText -FilePath 'cmd.exe' -Arguments @('/d', '/c', 'echo quick') -TimeoutSeconds 10

    Assert-Equal $result.TimedOut $false 'not timed out'
    Assert-Equal $result.StdOut.Trim() 'quick' 'stdout captured'
    Assert-Equal ($result.DurationSeconds -ge 0) $true 'duration present'
}
```

- [ ] **Step 2: Run the suite, expect both new tests to FAIL** (`A parameter cannot be found that matches parameter name 'TimeoutSeconds'`).

- [ ] **Step 3: Implement** — replace the body of `Invoke-NativeText`:

```powershell
function Invoke-NativeText {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 0,
        [string] $WorkingDirectory = ''
    )

    $resolvedPath = $FilePath
    if (-not [IO.Path]::IsPathRooted($FilePath) -and $FilePath -notmatch '[\\/]') {
        $commandPath = Resolve-ExternalCommandPath -CommandName $FilePath
        if ($commandPath) {
            $resolvedPath = $commandPath
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $TimeoutSeconds -gt 0
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new()
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new()
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    foreach ($argument in $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    [void] $process.Start()

    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            [void] $process.WaitForExit(5000)
        }

        # A detached grandchild can keep the pipes open; never block on it.
        $stdout = if ($stdoutTask.Wait(5000)) { $stdoutTask.Result } else { '' }
        $stderr = if ($stderrTask.Wait(5000)) { $stderrTask.Result } else { '' }
    }
    else {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
    }

    $stopwatch.Stop()

    [pscustomobject]@{
        ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
        StdOut = $stdout
        StdErr = $stderr
        Text = ($stdout + [Environment]::NewLine + $stderr)
        TimedOut = $timedOut
        DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
}
```

- [ ] **Step 4: Run the suite — all pass** (45 tests).
- [ ] **Step 5: Commit** — `git add src/Common.ps1 tests/run-tests.ps1; git commit -m "feat: timeout and duration for Invoke-NativeText"`

---

### Task 2: Health targets — model, GUI exe path, shim listing, agent catalog, PE subsystem

**Files:**
- Create: `src/Health.ps1`
- Modify: `src/ProgramUpdateAll.psm1` (dot-source `Health.ps1` after `Security.ps1`; export new public functions)
- Test: `tests/run-tests.ps1`

**Interfaces:**
- Produces:
  - `New-HealthTarget -Kind <Gui|Cli|Agent> -Name <string> -Source <string> [-Command <string>] [-Path <string>] [-ProbeArguments <string[]>] [-TimeoutSeconds <int>]` → `{ Key = "$Kind/$Source/$Name"; Kind; Name; Source; Command; Path; ProbeArguments; TimeoutSeconds }`
  - `ConvertFrom-UninstallExePath -DisplayIcon <string> [-InstallLocationFiles <string[]>] [-InstallLocation <string>]` → exe full path or `''`
  - `ConvertFrom-ShimListing -FileNames <string[]> -Source <string>` → unique command names (no extension), internal shims removed
  - `Get-HealthAgentCatalog` → `New-HealthTarget` objects of Kind `Agent` (codex, claude, opencode, agy, gemini, grok)
  - `Get-PeSubsystem -Path <string>` → `[int]` (2 = GUI, 3 = console, 0 = unknown)

- [ ] **Step 1: Write the failing tests**

```powershell
It 'builds a health target with a stable key' {
    $target = New-HealthTarget -Kind 'Cli' -Name 'rg' -Source 'choco' -Command 'C:\choco\bin\rg.exe' -ProbeArguments @('--version')

    Assert-Equal $target.Key 'Cli/choco/rg' 'target key'
    Assert-Equal $target.TimeoutSeconds 15 'default timeout'
    Assert-Equal $target.ProbeArguments[0] '--version' 'probe arguments'
}

It 'resolves a GUI exe from DisplayIcon and skips uninstallers' {
    Assert-Equal (ConvertFrom-UninstallExePath -DisplayIcon '"C:\Apps\Foo\foo.exe",0') 'C:\Apps\Foo\foo.exe' 'quoted icon with index'
    Assert-Equal (ConvertFrom-UninstallExePath -DisplayIcon 'C:\Apps\Foo\app.ico') '' 'ico is not an exe'
    Assert-Equal (ConvertFrom-UninstallExePath -DisplayIcon 'C:\Apps\Foo\unins000.exe' -InstallLocation 'C:\Apps\Foo' -InstallLocationFiles @('unins000.exe', 'Foo.exe')) 'C:\Apps\Foo\Foo.exe' 'falls back to install location, skipping uninstaller'
    Assert-Equal (ConvertFrom-UninstallExePath -DisplayIcon '' -InstallLocation '' -InstallLocationFiles @()) '' 'nothing to resolve'
}

It 'lists commands from a shim directory without internal shims' {
    $names = @(ConvertFrom-ShimListing -FileNames @('rg.exe', 'rg.exe.ignore', 'codex.cmd', 'codex', 'codex.ps1', 'volta-shim.exe', 'choco.exe', 'shimgen.exe') -Source 'npm')

    Assert-Equal ($names -join ',') 'choco,codex,rg' 'unique command names'
}

It 'catalogs AI agents with a PONG prompt and long timeout' {
    $agents = @(Get-HealthAgentCatalog)
    $codex = $agents | Where-Object Name -eq 'codex'

    Assert-Equal $agents.Count 6 'agent count'
    Assert-Equal $codex.Kind 'Agent' 'agent kind'
    Assert-Equal $codex.TimeoutSeconds 180 'agent timeout'
    Assert-Equal ($codex.ProbeArguments -contains 'Reply with the single word PONG') $true 'PONG prompt'
}

It 'reads the PE subsystem of console and GUI executables' {
    Assert-Equal (Get-PeSubsystem -Path "$env:windir\System32\cmd.exe") 3 'cmd is console'
    Assert-Equal (Get-PeSubsystem -Path "$env:windir\System32\notepad.exe") 2 'notepad is GUI'
    Assert-Equal (Get-PeSubsystem -Path "$env:windir\win.ini") 0 'not an exe'
}
```

- [ ] **Step 2: Run the suite — the 5 new tests FAIL** (`not recognized as a name of a cmdlet`).

- [ ] **Step 3: Implement** — create `src/Health.ps1`:

```powershell
# Health.ps1 — daily health check of installed programs.
# Pure builders/resolvers/formatters are tested; scanners that touch the
# registry, files, processes or Task Scheduler stay thin and untested.

$script:HealthPongPrompt = 'Reply with the single word PONG'

function New-HealthTarget {
    param(
        [Parameter(Mandatory)] [ValidateSet('Gui', 'Cli', 'Agent')] [string] $Kind,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Source,
        [string] $Command = '',
        [string] $Path = '',
        [string[]] $ProbeArguments = @(),
        [int] $TimeoutSeconds = 15
    )

    [pscustomobject]@{
        Key = "$Kind/$Source/$Name"
        Kind = $Kind
        Name = $Name
        Source = $Source
        Command = $Command
        Path = $Path
        ProbeArguments = $ProbeArguments
        TimeoutSeconds = $TimeoutSeconds
    }
}

function ConvertFrom-UninstallExePath {
    param(
        [AllowEmptyString()] [string] $DisplayIcon = '',
        [AllowEmptyString()] [string] $InstallLocation = '',
        [string[]] $InstallLocationFiles = @()
    )

    $uninstallerPattern = '^(unins\d*|uninstall.*|uninst.*)\.exe$'
    $icon = ($DisplayIcon -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
    if ($icon -match '\.exe$' -and (Split-Path $icon -Leaf) -notmatch $uninstallerPattern) {
        return $icon
    }

    if ([string]::IsNullOrWhiteSpace($InstallLocation)) {
        return ''
    }

    $exe = $InstallLocationFiles |
        Where-Object { $_ -match '\.exe$' -and $_ -notmatch $uninstallerPattern } |
        Select-Object -First 1
    if (-not $exe) {
        return ''
    }

    Join-Path $InstallLocation.Trim().Trim('"') $exe
}

function ConvertFrom-ShimListing {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $FileNames,
        [Parameter(Mandatory)] [string] $Source
    )

    $internal = @('volta-shim', 'volta', 'shimgen')
    $FileNames |
        Where-Object { $_ -match '^[^.]+(\.(exe|cmd|ps1))?$' } |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } |
        Where-Object { $internal -notcontains $_ } |
        Sort-Object -Unique
}

function Get-HealthAgentCatalog {
    $prompt = $script:HealthPongPrompt
    @(
        @{ Name = 'codex'; Arguments = @('exec', '--skip-git-repo-check', '--ephemeral', $prompt) }
        @{ Name = 'claude'; Arguments = @('-p', $prompt) }
        @{ Name = 'opencode'; Arguments = @('run', $prompt) }
        @{ Name = 'agy'; Arguments = @('-p', $prompt) }
        @{ Name = 'gemini'; Arguments = @('-p', $prompt) }
        @{ Name = 'grok'; Arguments = @('-p', $prompt) }
    ) | ForEach-Object {
        New-HealthTarget -Kind 'Agent' -Name $_.Name -Source 'agent' -Command $_.Name -ProbeArguments $_.Arguments -TimeoutSeconds 180
    }
}

function Get-PeSubsystem {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $reader = [IO.BinaryReader]::new($stream)
            if ($reader.ReadUInt16() -ne 0x5A4D) { return 0 }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { return 0 }
            # Subsystem sits at optional header + 68 (same for PE32 and PE32+).
            $stream.Position = $peOffset + 24 + 68
            [int] $reader.ReadUInt16()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        0
    }
}
```

In `src/ProgramUpdateAll.psm1` add `. (Join-Path $PSScriptRoot 'Health.ps1')` after the `Security.ps1` line and add to `Export-ModuleMember`: `'New-HealthTarget'`, `'ConvertFrom-UninstallExePath'`, `'ConvertFrom-ShimListing'`, `'Get-HealthAgentCatalog'`, `'Get-PeSubsystem'`.

- [ ] **Step 4: Run the suite — all pass.**
- [ ] **Step 5: Commit** — `git add src/Health.ps1 src/ProgramUpdateAll.psm1 tests/run-tests.ps1; git commit -m "feat(health): targets, exe resolution, shim listing, agent catalog"`

---

### Task 3: Probe status resolution

**Files:** Modify `src/Health.ps1`, `src/ProgramUpdateAll.psm1` (exports); Test `tests/run-tests.ps1`

**Interfaces:**
- Consumes: `New-HealthTarget` (Task 2), `Invoke-NativeText` result shape (Task 1).
- Produces:
  - `New-HealthResult -Target <object> -Status <string> [-DurationSeconds <double>] [-Version <string>] [-Detail <string>]` → `{ Key; Kind; Name; Source; Status; DurationSeconds; Version; Detail; CheckedAt }` (`CheckedAt` ISO-8601 string)
  - `Resolve-HealthProbeResult -Target <object> [-NativeResult <object>] [-ErrorMessage <string>]` → `New-HealthResult` (Cli/Agent)
  - `Resolve-GuiHealthResult -Target <object> -Exists <bool> [-SignatureStatus <string>] [-FileVersion <string>]` → `New-HealthResult`
  - Statuses: `OK`, `Missing`, `Broken`, `Failed`, `TimedOut`, `Slow`, `Warn`.

- [ ] **Step 1: Write the failing tests**

```powershell
It 'resolves CLI and agent probe results into health statuses' {
    $cli = New-HealthTarget -Kind 'Cli' -Name 'rg' -Source 'choco'
    $agent = New-HealthTarget -Kind 'Agent' -Name 'codex' -Source 'agent'
    $ok = [pscustomobject]@{ ExitCode = 2; StdOut = 'usage: rg'; StdErr = ''; TimedOut = $false; DurationSeconds = 0.4 }
    $pong = [pscustomobject]@{ ExitCode = 0; StdOut = "PONG`n"; StdErr = ''; TimedOut = $false; DurationSeconds = 28.6 }
    $silent = [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = 'auth error'; TimedOut = $false; DurationSeconds = 3 }
    $hung = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $true; DurationSeconds = 180 }

    Assert-Equal (Resolve-HealthProbeResult -Target $cli -NativeResult $ok).Status 'OK' 'CLI that runs is OK even with a non-zero exit code'
    Assert-Equal (Resolve-HealthProbeResult -Target $cli -NativeResult $ok).Version '' 'no version parsed from usage text'
    Assert-Equal (Resolve-HealthProbeResult -Target $agent -NativeResult $pong).Status 'OK' 'agent answered PONG'
    Assert-Equal (Resolve-HealthProbeResult -Target $agent -NativeResult $pong).DurationSeconds 28.6 'agent duration kept'
    Assert-Equal (Resolve-HealthProbeResult -Target $agent -NativeResult $silent).Status 'Failed' 'agent without PONG failed'
    Assert-Equal ((Resolve-HealthProbeResult -Target $agent -NativeResult $silent).Detail -match 'auth error') $true 'failure detail from stderr'
    Assert-Equal (Resolve-HealthProbeResult -Target $agent -NativeResult $hung).Status 'TimedOut' 'agent timed out'
    Assert-Equal (Resolve-HealthProbeResult -Target $cli -ErrorMessage 'file not found').Status 'Failed' 'launch error'
}

It 'parses a version from CLI output' {
    $cli = New-HealthTarget -Kind 'Cli' -Name 'codex' -Source 'volta'
    $result = [pscustomobject]@{ ExitCode = 0; StdOut = 'codex-cli 0.156.1'; StdErr = ''; TimedOut = $false; DurationSeconds = 0.3 }

    Assert-Equal (Resolve-HealthProbeResult -Target $cli -NativeResult $result).Version '0.156.1' 'normalized version'
}

It 'resolves GUI health from exe presence and signature' {
    $gui = New-HealthTarget -Kind 'Gui' -Name 'Foo' -Source 'HKLM' -Path 'C:\Apps\foo.exe'

    Assert-Equal (Resolve-GuiHealthResult -Target $gui -Exists $false).Status 'Missing' 'missing exe'
    Assert-Equal (Resolve-GuiHealthResult -Target $gui -Exists $true -SignatureStatus 'HashMismatch').Status 'Broken' 'tampered exe'
    Assert-Equal (Resolve-GuiHealthResult -Target $gui -Exists $true -SignatureStatus 'NotSigned' -FileVersion '1.2.3').Status 'OK' 'unsigned is fine'
    Assert-Equal (Resolve-GuiHealthResult -Target $gui -Exists $true -SignatureStatus 'Valid' -FileVersion '1.2.3').Version '1.2.3' 'file version kept'
}
```

- [ ] **Step 2: Run — the 3 new tests FAIL.**

- [ ] **Step 3: Implement** — append to `src/Health.ps1`:

```powershell
function New-HealthResult {
    param(
        [Parameter(Mandatory)] [object] $Target,
        [Parameter(Mandatory)] [string] $Status,
        [double] $DurationSeconds = 0,
        [string] $Version = '',
        [string] $Detail = ''
    )

    [pscustomobject]@{
        Key = $Target.Key
        Kind = $Target.Kind
        Name = $Target.Name
        Source = $Target.Source
        Status = $Status
        DurationSeconds = $DurationSeconds
        Version = $Version
        Detail = $Detail
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Resolve-HealthProbeResult {
    param(
        [Parameter(Mandatory)] [object] $Target,
        [object] $NativeResult = $null,
        [string] $ErrorMessage = ''
    )

    if ($ErrorMessage -or -not $NativeResult) {
        return New-HealthResult -Target $Target -Status 'Failed' -Detail $ErrorMessage
    }

    $duration = [double] $NativeResult.DurationSeconds
    if ($NativeResult.TimedOut) {
        return New-HealthResult -Target $Target -Status 'TimedOut' -DurationSeconds $duration -Detail "no answer within $($Target.TimeoutSeconds) s"
    }

    if ($Target.Kind -eq 'Agent') {
        if ($NativeResult.StdOut -match '\bPONG\b') {
            return New-HealthResult -Target $Target -Status 'OK' -DurationSeconds $duration
        }

        $detail = (($NativeResult.StdErr + ' ' + $NativeResult.StdOut) -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        return New-HealthResult -Target $Target -Status 'Failed' -DurationSeconds $duration -Detail $detail
    }

    $firstLine = (($NativeResult.StdOut + "`n" + $NativeResult.StdErr) -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $version = if ($firstLine) { Normalize-VersionString -Version $firstLine } else { '' }
    New-HealthResult -Target $Target -Status 'OK' -DurationSeconds $duration -Version $version
}

function Resolve-GuiHealthResult {
    param(
        [Parameter(Mandatory)] [object] $Target,
        [Parameter(Mandatory)] [bool] $Exists,
        [string] $SignatureStatus = '',
        [string] $FileVersion = ''
    )

    if (-not $Exists) {
        return New-HealthResult -Target $Target -Status 'Missing' -Detail "exe not found: $($Target.Path)"
    }

    if ($SignatureStatus -eq 'HashMismatch') {
        return New-HealthResult -Target $Target -Status 'Broken' -Version $FileVersion -Detail 'signature hash mismatch'
    }

    New-HealthResult -Target $Target -Status 'OK' -Version $FileVersion
}
```

Export `'New-HealthResult'`, `'Resolve-HealthProbeResult'`, `'Resolve-GuiHealthResult'`.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(health): resolve probe results into statuses"`

---

### Task 4: Environment findings — duplicate installs and codex state

**Files:** Modify `src/Health.ps1`, exports; Test `tests/run-tests.ps1`

**Interfaces:**
- Consumes: `New-HealthResult`, `New-HealthTarget`.
- Produces:
  - `Find-DuplicateCommands -Results <object[]>` → `Warn` results with Kind `Env`, Name = command, Detail = `"<source> <version>, <source> <version>"`
  - `Get-CodexStateFindings -CodexHome <string> [-StagingFileLimit <int> = 10000]` → `Warn` results (0..2)

- [ ] **Step 1: Write the failing tests**

```powershell
It 'flags a command installed from several sources with different versions' {
    $results = @(
        [pscustomobject]@{ Kind = 'Cli'; Name = 'codex'; Source = 'volta'; Version = '0.156.1'; Status = 'OK' }
        [pscustomobject]@{ Kind = 'Cli'; Name = 'codex'; Source = 'npm'; Version = '0.154.0'; Status = 'OK' }
        [pscustomobject]@{ Kind = 'Cli'; Name = 'rg'; Source = 'choco'; Version = '14.1.0'; Status = 'OK' }
        [pscustomobject]@{ Kind = 'Cli'; Name = 'rg'; Source = 'scoop'; Version = '14.1.0'; Status = 'OK' }
    )

    $findings = @(Find-DuplicateCommands -Results $results)

    Assert-Equal $findings.Count 1 'only differing versions are flagged'
    Assert-Equal $findings[0].Name 'codex' 'duplicate command name'
    Assert-Equal $findings[0].Status 'Warn' 'duplicate is a warning'
    Assert-Equal ($findings[0].Detail -match 'npm 0\.154\.0') $true 'detail lists sources'
}

It 'reports codex sandbox setup errors and bloated marketplace staging' {
    $codexHome = Join-Path ([IO.Path]::GetTempPath()) "pck-codex-$([guid]::NewGuid().ToString('N'))"
    $staging = Join-Path $codexHome '.tmp\marketplaces\.staging'
    New-Item -ItemType Directory -Force (Join-Path $codexHome '.sandbox'), $staging | Out-Null
    try {
        Assert-Equal @(Get-CodexStateFindings -CodexHome $codexHome -StagingFileLimit 3).Count 0 'clean state'

        Set-Content (Join-Path $codexHome '.sandbox\setup_error.json') '{"code":"x"}'
        1..4 | ForEach-Object { Set-Content (Join-Path $staging "f$_.txt") 'x' }
        $findings = @(Get-CodexStateFindings -CodexHome $codexHome -StagingFileLimit 3)

        Assert-Equal $findings.Count 2 'both findings'
        Assert-Equal ($findings.Name -contains 'codex sandbox') $true 'sandbox finding'
        Assert-Equal ($findings.Name -contains 'codex marketplace staging') $true 'staging finding'
    }
    finally {
        Remove-Item -Recurse -Force $codexHome
    }
}
```

- [ ] **Step 2: Run — 2 new tests FAIL.**

- [ ] **Step 3: Implement** — append:

```powershell
function Find-DuplicateCommands {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $Results |
        Where-Object { $_.Kind -eq 'Cli' -and $_.Version } |
        Group-Object Name |
        Where-Object { @($_.Group.Version | Sort-Object -Unique).Count -gt 1 } |
        ForEach-Object {
            $detail = ($_.Group | ForEach-Object { "$($_.Source) $($_.Version)" }) -join ', '
            $target = New-HealthTarget -Kind 'Cli' -Name $_.Name -Source 'env'
            $finding = New-HealthResult -Target $target -Status 'Warn' -Detail "installed several times: $detail"
            $finding.Kind = 'Env'
            $finding.Key = "Env/duplicate/$($_.Name)"
            $finding
        }
}

function Get-CodexStateFindings {
    param(
        [Parameter(Mandatory)] [string] $CodexHome,
        [int] $StagingFileLimit = 10000
    )

    $findings = @()
    if (Test-Path -LiteralPath (Join-Path $CodexHome '.sandbox\setup_error.json')) {
        $findings += [pscustomobject]@{ Name = 'codex sandbox'; Detail = 'sandbox setup failed (.sandbox\setup_error.json); codex starts slowly' }
    }

    $staging = Join-Path $CodexHome '.tmp\marketplaces\.staging'
    if (Test-Path -LiteralPath $staging) {
        $count = @([IO.Directory]::EnumerateFiles($staging, '*', [IO.SearchOption]::AllDirectories) | Select-Object -First ($StagingFileLimit + 1)).Count
        if ($count -gt $StagingFileLimit) {
            $findings += [pscustomobject]@{ Name = 'codex marketplace staging'; Detail = "more than $StagingFileLimit leftover files in .tmp\marketplaces\.staging; codex starts slowly" }
        }
    }

    foreach ($finding in $findings) {
        $target = New-HealthTarget -Kind 'Cli' -Name $finding.Name -Source 'env'
        $result = New-HealthResult -Target $target -Status 'Warn' -Detail $finding.Detail
        $result.Kind = 'Env'
        $result.Key = "Env/codex/$($finding.Name)"
        $result
    }
}
```

Export `'Find-DuplicateCommands'`, `'Get-CodexStateFindings'`.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(health): duplicate install and codex state findings"`

---

### Task 5: Slowdown verdict and history

**Files:** Modify `src/Health.ps1`, exports; Test `tests/run-tests.ps1`

**Interfaces:**
- Consumes: result shape from Task 3.
- Produces:
  - `Get-HealthVerdict -Result <object> -History <object[]>` → the same result, `Status = 'Slow'` + `Detail = "took N s, usually M s"` when slow
  - `Save-HealthResults -Directory <string> -Results <object[]> [-Date <datetime>]` → writes `<yyyy-MM-dd>.json` (overwrites the day), prunes files older than 30 days
  - `Read-HealthHistory -Directory <string> [-Days <int> = 14]` → flattened past results

- [ ] **Step 1: Write the failing tests**

```powershell
It 'marks a probe slow against its recent median' {
    $history = @(20, 25, 30, 28, 26) | ForEach-Object { [pscustomobject]@{ Key = 'Agent/agent/codex'; Status = 'OK'; DurationSeconds = $_ } }
    $slow = [pscustomobject]@{ Key = 'Agent/agent/codex'; Status = 'OK'; DurationSeconds = 100; Detail = '' }
    $normal = [pscustomobject]@{ Key = 'Agent/agent/codex'; Status = 'OK'; DurationSeconds = 40; Detail = '' }
    $fastButDouble = [pscustomobject]@{ Key = 'Cli/x/y'; Status = 'OK'; DurationSeconds = 5; Detail = '' }
    $fastHistory = @(1, 1, 1) | ForEach-Object { [pscustomobject]@{ Key = 'Cli/x/y'; Status = 'OK'; DurationSeconds = $_ } }

    Assert-Equal (Get-HealthVerdict -Result $slow -History $history).Status 'Slow' 'over twice the median'
    Assert-Equal ((Get-HealthVerdict -Result $slow -History $history).Detail -match 'usually 26') $true 'detail shows the median'
    Assert-Equal (Get-HealthVerdict -Result $normal -History $history).Status 'OK' 'within twice the median'
    Assert-Equal (Get-HealthVerdict -Result $fastButDouble -History $fastHistory).Status 'OK' 'under the 30 s floor'
    Assert-Equal (Get-HealthVerdict -Result $slow -History @($history[0], $history[1])).Status 'OK' 'too little history'
}

It 'saves health results per day and reads them back as history' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "pck-health-$([guid]::NewGuid().ToString('N'))"
    try {
        $r = [pscustomobject]@{ Key = 'Agent/agent/codex'; Kind = 'Agent'; Name = 'codex'; Source = 'agent'; Status = 'OK'; DurationSeconds = 28.6; Version = ''; Detail = ''; CheckedAt = '' }
        Save-HealthResults -Directory $dir -Results @($r) -Date (Get-Date).AddDays(-1)
        Save-HealthResults -Directory $dir -Results @($r) -Date (Get-Date).AddDays(-40)

        $history = @(Read-HealthHistory -Directory $dir)

        Assert-Equal $history.Count 1 'old day pruned, recent day read'
        Assert-Equal $history[0].DurationSeconds 28.6 'duration round-trips'
    }
    finally {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Run — 2 new tests FAIL.**

- [ ] **Step 3: Implement** — append:

```powershell
function Get-HealthVerdict {
    param(
        [Parameter(Mandatory)] [object] $Result,
        [AllowEmptyCollection()] [object[]] $History = @()
    )

    if ($Result.Status -ne 'OK') {
        return $Result
    }

    $durations = @($History |
        Where-Object { $_.Key -eq $Result.Key -and $_.Status -eq 'OK' -and $_.DurationSeconds -gt 0 } |
        Select-Object -Last 7 |
        ForEach-Object { [double] $_.DurationSeconds } |
        Sort-Object)
    if ($durations.Count -lt 3) {
        return $Result
    }

    $mid = [int][Math]::Floor($durations.Count / 2)
    $median = if ($durations.Count % 2) { $durations[$mid] } else { ($durations[$mid - 1] + $durations[$mid]) / 2 }
    if ($Result.DurationSeconds -gt 2 * $median -and $Result.DurationSeconds -gt 30) {
        $Result.Status = 'Slow'
        $Result.Detail = "took $([Math]::Round($Result.DurationSeconds)) s, usually $([Math]::Round($median)) s"
    }

    $Result
}

function Save-HealthResults {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        [datetime] $Date = (Get-Date)
    )

    New-Item -ItemType Directory -Force $Directory | Out-Null
    $path = Join-Path $Directory ($Date.ToString('yyyy-MM-dd') + '.json')
    ConvertTo-Json -InputObject @($Results) -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8

    $cutoff = (Get-Date).Date.AddDays(-30)
    Get-ChildItem -LiteralPath $Directory -Filter '????-??-??.json' |
        Where-Object { [datetime]::ParseExact($_.BaseName, 'yyyy-MM-dd', $null) -lt $cutoff } |
        Remove-Item -Force
}

function Read-HealthHistory {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [int] $Days = 14
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    $cutoff = (Get-Date).Date.AddDays(-$Days)
    Get-ChildItem -LiteralPath $Directory -Filter '????-??-??.json' |
        Where-Object { [datetime]::ParseExact($_.BaseName, 'yyyy-MM-dd', $null) -ge $cutoff } |
        Sort-Object Name |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
        ForEach-Object { $_ }
}
```

Export `'Get-HealthVerdict'`, `'Save-HealthResults'`, `'Read-HealthHistory'`.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(health): slowdown verdict and daily history"`

---

### Task 6: Report text and notification text

**Files:** Modify `src/Health.ps1`, exports; Test `tests/run-tests.ps1`

**Interfaces:**
- Produces:
  - `Test-IsHealthProblem -Result <object>` → `[bool]` (problem statuses: `Broken`, `Failed`, `TimedOut`, `Slow`, `Warn`; `Missing` only for Kind `Gui`)
  - `Format-HealthNotification -Results <object[]>` → `$null` or `{ Title; Lines [string[]] }` (≤ 3 lines + `"+N more"`)
  - `ConvertTo-HealthReportText -Results <object[]>` → string (problems first, then counts by Kind)

- [ ] **Step 1: Write the failing tests**

```powershell
It 'builds a toast only when there are problems' {
    $ok = [pscustomobject]@{ Kind = 'Cli'; Name = 'rg'; Status = 'OK'; Detail = '' }
    $agentMissing = [pscustomobject]@{ Kind = 'Agent'; Name = 'grok'; Status = 'Missing'; Detail = '' }
    Assert-Equal (Format-HealthNotification -Results @($ok, $agentMissing)) $null 'no toast when healthy'

    $problems = @(
        [pscustomobject]@{ Kind = 'Agent'; Name = 'codex'; Status = 'Slow'; Detail = 'took 100 s, usually 26 s' }
        [pscustomobject]@{ Kind = 'Cli'; Name = 'foo'; Status = 'TimedOut'; Detail = 'no answer within 15 s' }
        [pscustomobject]@{ Kind = 'Gui'; Name = 'Bar'; Status = 'Missing'; Detail = 'exe not found' }
        [pscustomobject]@{ Kind = 'Env'; Name = 'codex'; Status = 'Warn'; Detail = 'installed several times' }
    )
    $toast = Format-HealthNotification -Results ($problems + $ok)

    Assert-Equal $toast.Title 'PC Keeper: 4 program problem(s)' 'toast title'
    Assert-Equal $toast.Lines.Count 4 'three problems plus a more line'
    Assert-Equal $toast.Lines[0] 'codex: Slow - took 100 s, usually 26 s' 'first line'
    Assert-Equal $toast.Lines[3] '+1 more' 'overflow line'
}

It 'renders a health report with problems first' {
    $results = @(
        [pscustomobject]@{ Kind = 'Cli'; Name = 'rg'; Source = 'choco'; Status = 'OK'; DurationSeconds = 0.3; Version = '14.1.0'; Detail = '' }
        [pscustomobject]@{ Kind = 'Agent'; Name = 'codex'; Source = 'agent'; Status = 'Slow'; DurationSeconds = 100; Version = ''; Detail = 'took 100 s, usually 26 s' }
    )

    $text = ConvertTo-HealthReportText -Results $results

    Assert-Equal ($text -match 'PC Keeper Health') $true 'heading'
    Assert-Equal ($text.IndexOf('codex') -lt $text.IndexOf('rg')) $true 'problem listed before healthy'
    Assert-Equal ($text -match 'Cli: 1 checked') $true 'per-kind counts'
}
```

- [ ] **Step 2: Run — 2 new tests FAIL.**

- [ ] **Step 3: Implement** — append:

```powershell
function Test-IsHealthProblem {
    param(
        [Parameter(Mandatory)] [object] $Result
    )

    if ($Result.Status -eq 'Missing') {
        return $Result.Kind -eq 'Gui'
    }

    @('Broken', 'Failed', 'TimedOut', 'Slow', 'Warn') -contains $Result.Status
}

function Format-HealthNotification {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $problems = @($Results | Where-Object { Test-IsHealthProblem -Result $_ })
    if ($problems.Count -eq 0) {
        return $null
    }

    $lines = @($problems | Select-Object -First 3 | ForEach-Object {
        if ($_.Detail) { "$($_.Name): $($_.Status) - $($_.Detail)" } else { "$($_.Name): $($_.Status)" }
    })
    if ($problems.Count -gt 3) {
        $lines += "+$($problems.Count - 3) more"
    }

    [pscustomobject]@{
        Title = "PC Keeper: $($problems.Count) program problem(s)"
        Lines = $lines
    }
}

function ConvertTo-HealthReportText {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $builder = [Text.StringBuilder]::new()
    [void] $builder.AppendLine("PC Keeper Health - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void] $builder.AppendLine('')

    $problems = @($Results | Where-Object { Test-IsHealthProblem -Result $_ })
    [void] $builder.AppendLine("Problems: $($problems.Count)")
    foreach ($r in $problems) {
        [void] $builder.AppendLine("  [$($r.Status)] $($r.Kind) $($r.Name) ($($r.Source)) $($r.Detail)")
    }

    [void] $builder.AppendLine('')
    foreach ($group in ($Results | Group-Object Kind | Sort-Object Name)) {
        $okCount = @($group.Group | Where-Object Status -eq 'OK').Count
        [void] $builder.AppendLine("$($group.Name): $($group.Count) checked, $okCount OK")
    }

    [void] $builder.AppendLine('')
    foreach ($r in ($Results | Where-Object { -not (Test-IsHealthProblem -Result $_) } | Sort-Object Kind, Name)) {
        [void] $builder.AppendLine("  [$($r.Status)] $($r.Kind) $($r.Name) ($($r.Source)) $($r.Version) $($r.DurationSeconds)s")
    }

    $builder.ToString()
}
```

Export `'Test-IsHealthProblem'`, `'Format-HealthNotification'`, `'ConvertTo-HealthReportText'`.

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(health): report and notification text"`

---

### Task 7: Scanners, probes, orchestration, toast (thin, not unit-tested)

**Files:** Modify `src/Health.ps1`, exports

**Interfaces:**
- Consumes: everything above; `Get-NpmGlobalPackageInventory` is NOT used (package ≠ command name) — CLI discovery reads shim directories instead.
- Produces:
  - `Get-HealthDataDirectory` → `%LOCALAPPDATA%\pc-keeper\health`
  - `Get-HealthTargets` → all targets
  - `Invoke-HealthProbe -Target <object>` → result
  - `Invoke-HealthCheck [-Quiet]` → results (saves history, `latest.txt`, toast on problems)
  - `Show-HealthToast -Title <string> -Lines <string[]>`

- [ ] **Step 1: Implement** — append:

```powershell
function Get-HealthDataDirectory {
    Join-Path $env:LOCALAPPDATA 'pc-keeper\health'
}

function Get-HealthShimDirectories {
    @(
        @{ Source = 'volta'; Path = Join-Path $env:LOCALAPPDATA 'Volta\bin' }
        @{ Source = 'npm'; Path = Join-Path $env:APPDATA 'npm' }
        @{ Source = 'choco'; Path = 'C:\ProgramData\chocolatey\bin' }
        @{ Source = 'scoop'; Path = Join-Path $env:USERPROFILE 'scoop\shims' }
    ) | Where-Object { Test-Path -LiteralPath $_.Path }
}

function Get-HealthTargets {
    $targets = @()

    foreach ($dir in Get-HealthShimDirectories) {
        $files = @(Get-ChildItem -LiteralPath $dir.Path -File | Select-Object -ExpandProperty Name)
        foreach ($name in ConvertFrom-ShimListing -FileNames $files -Source $dir.Source) {
            # Process.Start can run .exe and .cmd directly; .ps1 and extensionless sh shims it cannot.
            $file = @('.exe', '.cmd') |
                ForEach-Object { Join-Path $dir.Path "$name$_" } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if (-not $file) { continue }
            if ($file -match '\.exe$' -and (Get-PeSubsystem -Path $file) -ne 3) { continue }
            $targets += New-HealthTarget -Kind 'Cli' -Name $name -Source $dir.Source -Command $file -ProbeArguments @('--version')
        }
    }

    $uninstallPaths = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKLM' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKLM-WOW6432' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKCU' }
    )
    $seenGui = @{}
    foreach ($path in $uninstallPaths) {
        foreach ($entry in (Get-ItemProperty -Path $path.Path -ErrorAction SilentlyContinue)) {
            $item = ConvertFrom-UninstallRegistryEntry -Entry $entry -Source $path.Source
            if (-not $item -or $seenGui.ContainsKey($item.Name)) { continue }
            $icon = if ($entry.PSObject.Properties.Name -contains 'DisplayIcon') { [string] $entry.DisplayIcon } else { '' }
            $files = @()
            if ($item.InstallLocation -and (Test-Path -LiteralPath $item.InstallLocation.Trim('"'))) {
                $files = @(Get-ChildItem -LiteralPath $item.InstallLocation.Trim('"') -Filter *.exe -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            }
            $exe = ConvertFrom-UninstallExePath -DisplayIcon $icon -InstallLocation $item.InstallLocation -InstallLocationFiles $files
            if (-not $exe) { continue }
            $seenGui[$item.Name] = $true
            $targets += New-HealthTarget -Kind 'Gui' -Name $item.Name -Source $path.Source -Path $exe
        }
    }

    $targets + @(Get-HealthAgentCatalog)
}

function Invoke-HealthProbe {
    param(
        [Parameter(Mandatory)] [object] $Target
    )

    if ($Target.Kind -eq 'Gui') {
        $exists = Test-Path -LiteralPath $Target.Path -PathType Leaf
        $signature = ''
        $version = ''
        if ($exists) {
            $signature = [string] (Get-AuthenticodeSignature -LiteralPath $Target.Path -ErrorAction SilentlyContinue).Status
            $version = [string] (Get-Item -LiteralPath $Target.Path).VersionInfo.FileVersion
        }
        return Resolve-GuiHealthResult -Target $Target -Exists $exists -SignatureStatus $signature -FileVersion $version
    }

    if ($Target.Kind -eq 'Agent' -and -not (Test-CommandAvailable -Name $Target.Command)) {
        return New-HealthResult -Target $Target -Status 'Missing' -Detail 'not installed'
    }

    $cwd = Join-Path (Get-HealthDataDirectory) 'probe-cwd'
    New-Item -ItemType Directory -Force $cwd | Out-Null
    try {
        $native = Invoke-NativeText -FilePath $Target.Command -Arguments $Target.ProbeArguments -TimeoutSeconds $Target.TimeoutSeconds -WorkingDirectory $cwd
        Resolve-HealthProbeResult -Target $Target -NativeResult $native
    }
    catch {
        Resolve-HealthProbeResult -Target $Target -ErrorMessage $_.Exception.Message
    }
}

function Show-HealthToast {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string[]] $Lines
    )

    $escape = { param($s) [Security.SecurityElement]::Escape($s) }
    $texts = (@($Title) + $Lines | ForEach-Object { "<text>$(& $escape $_)</text>" }) -join ''
    $script = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml('<toast><visual><binding template="ToastGeneric">$texts</binding></visual></toast>')
`$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Invoke-NativeText -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-EncodedCommand', $encoded) -TimeoutSeconds 30 | Out-Null
}

function Invoke-HealthCheck {
    param(
        [switch] $Quiet
    )

    $dir = Get-HealthDataDirectory
    $history = @(Read-HealthHistory -Directory $dir)
    $targets = @(Get-HealthTargets)

    $results = @()
    $i = 0
    foreach ($target in $targets) {
        $i++
        if (-not $Quiet) {
            Write-Progress -Activity 'Checking programs' -Status "$($target.Kind) $($target.Name)" -PercentComplete (100 * $i / $targets.Count)
        }
        $results += Get-HealthVerdict -Result (Invoke-HealthProbe -Target $target) -History $history
    }
    if (-not $Quiet) {
        Write-Progress -Activity 'Checking programs' -Completed
    }

    $results += @(Find-DuplicateCommands -Results $results)
    $results += @(Get-CodexStateFindings -CodexHome (Join-Path $env:USERPROFILE '.codex'))

    Save-HealthResults -Directory $dir -Results $results
    ConvertTo-HealthReportText -Results $results | Set-Content -LiteralPath (Join-Path $dir 'latest.txt') -Encoding utf8

    $toast = Format-HealthNotification -Results $results
    if ($toast) {
        Show-HealthToast -Title $toast.Title -Lines $toast.Lines
    }

    $results
}
```

Export `'Get-HealthDataDirectory'`, `'Get-HealthTargets'`, `'Invoke-HealthProbe'`, `'Invoke-HealthCheck'`, `'Show-HealthToast'`.

- [ ] **Step 2: Run the suite — all pass (no new tests; nothing regressed).**
- [ ] **Step 3: Manual check** — `Import-Module .\src\ProgramUpdateAll.psm1 -Force; $t = Get-HealthTargets; $t | Group-Object Kind | Select Name,Count` (expect Cli > 0, Gui > 0, Agent 6). Then `Invoke-HealthProbe -Target ($t | Where Name -eq 'codex' | Where Kind -eq 'Agent')` → Status OK with DurationSeconds; `Show-HealthToast -Title 'PC Keeper test' -Lines @('toast works')` → a toast appears.
- [ ] **Step 4: Commit** — `git commit -am "feat(health): scanners, probes, orchestration and toast"`

---

### Task 8: Entry points — `-Health`, `-Quiet`, `-RegisterSchedule`, menu

**Files:**
- Modify: `src/Health.ps1` (schedule builder + register + show), `src/Update.ps1` (`Invoke-ProgramUpdateAll` params/dispatch), `program-update-all.ps1` (params), `src/Ui.ps1` (`Get-MainMenuItems`, `Invoke-PcKeeper`), `src/ProgramUpdateAll.psm1` (exports), `README.md`, `CLAUDE.md` (Commands block)
- Test: `tests/run-tests.ps1` (new test + update the main-menu test to 5 items)

**Interfaces:**
- Produces:
  - `New-HealthScheduleAction -ScriptPath <string>` → `{ Execute; Argument }` (pure)
  - `Register-HealthSchedule` → registers `PcKeeperHealthCheck`
  - `Show-HealthReport -Results <object[]>`
  - main menu item `@{ Id = 'health'; Title = 'Program Health'; Subtitle = 'Check that installed programs start and respond' }`

- [ ] **Step 1: Write the failing tests** — add, and change the existing `'exposes the four PC Keeper pillars in the main menu'` test to:

```powershell
It 'builds a hidden scheduled task action for the health check' {
    $action = New-HealthScheduleAction -ScriptPath 'D:\pc-keeper\program-update-all.ps1'

    Assert-Equal $action.Execute 'C:\Windows\System32\conhost.exe' 'runs through conhost'
    Assert-Equal ($action.Argument.StartsWith('--headless pwsh ')) $true 'headless pwsh'
    Assert-Equal ($action.Argument -match '-File "D:\\pc-keeper\\program-update-all\.ps1" -Health -Quiet$') $true 'health quiet mode'
}

It 'exposes the PC Keeper pillars in the main menu' {
    $items = @(Get-MainMenuItems)

    Assert-Equal $items.Count 5 'main menu pillar count'
    Assert-Equal $items[0].Id 'updates' 'first pillar is updates'
    Assert-Equal $items[1].Id 'audit' 'second pillar is audit'
    Assert-Equal $items[2].Id 'cleanup' 'third pillar is cleanup'
    Assert-Equal $items[3].Id 'security' 'fourth pillar is security'
    Assert-Equal $items[4].Id 'health' 'fifth pillar is program health'
}
```

- [ ] **Step 2: Run — the 2 tests FAIL.**

- [ ] **Step 3: Implement.**

Append to `src/Health.ps1`:

```powershell
function New-HealthScheduleAction {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    [pscustomobject]@{
        Execute = 'C:\Windows\System32\conhost.exe'
        Argument = "--headless pwsh -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Health -Quiet"
    }
}

function Register-HealthSchedule {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'program-update-all.ps1'
    $spec = New-HealthScheduleAction -ScriptPath $scriptPath
    $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $logon.Delay = 'PT5M'
    $daily = New-ScheduledTaskTrigger -Daily -At '12:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName 'PcKeeperHealthCheck' -Action $action -Trigger @($logon, $daily) -Settings $settings -Description 'PC Keeper: daily health check of installed programs' -Force | Out-Null
    Write-Host "Registered scheduled task PcKeeperHealthCheck (at logon +5 min and daily 12:00). Report: $(Join-Path (Get-HealthDataDirectory) 'latest.txt')"
}

function Show-HealthReport {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    Write-Header -Title 'Program Health' -Subtitle "$($Results.Count) checks"
    foreach ($r in ($Results | Sort-Object { -not (Test-IsHealthProblem -Result $_) }, Kind, Name)) {
        $status = if (Test-IsHealthProblem -Result $r) { if ($r.Status -in 'Warn', 'Slow') { 'Warn' } else { 'Bad' } } elseif ($r.Status -eq 'OK') { 'Ok' } else { 'Info' }
        if ($status -eq 'Ok' -and $r.Kind -eq 'Gui') { continue }
        $value = (@($r.Status, $r.Version, $(if ($r.DurationSeconds) { "$($r.DurationSeconds)s" }), $r.Detail) | Where-Object { $_ }) -join '  '
        Write-StatusLine -Status $status -Label "$($r.Kind) $($r.Name) [$($r.Source)]" -Value $value
    }
    $okGui = @($Results | Where-Object { $_.Kind -eq 'Gui' -and $_.Status -eq 'OK' }).Count
    Write-StatusLine -Status 'Ok' -Label 'GUI programs OK' -Value "$okGui"
    Write-Host "Full report: $(Join-Path (Get-HealthDataDirectory) 'latest.txt')"
}
```

`src/Update.ps1` — in `Invoke-ProgramUpdateAll` add params `[switch] $Health, [switch] $Quiet, [switch] $RegisterSchedule` and, before the `if ($Doctor)` block:

```powershell
    if ($Health) {
        if ($RegisterSchedule) {
            Register-HealthSchedule
            return
        }

        $results = @(Invoke-HealthCheck -Quiet:$Quiet)
        if (-not $Quiet) {
            Show-HealthReport -Results $results
        }
        return
    }
```

`program-update-all.ps1` — add `[switch] $Health, [switch] $Quiet, [switch] $RegisterSchedule` to its `param()`.

`src/Ui.ps1` — `Get-MainMenuItems` gets a fifth item `[pscustomobject]@{ Id = 'health'; Title = 'Program Health'; Subtitle = 'Check that installed programs start and respond' }`; `Invoke-PcKeeper` switch gets:

```powershell
            'health' {
                Clear-Host
                $results = @(Invoke-HealthCheck)
                Show-HealthReport -Results $results
            }
```

Export `'New-HealthScheduleAction'`, `'Register-HealthSchedule'`, `'Show-HealthReport'`.

Docs: in `README.md` and in the `CLAUDE.md` Commands block add
```
.\program-update-all.cmd -Health                    # check that installed programs start and respond
.\program-update-all.cmd -Health -RegisterSchedule  # daily hidden check + toast on problems
```

- [ ] **Step 4: Run — all pass.**
- [ ] **Step 5: Real run** — `.\program-update-all.cmd -Health` (expect a report; agents OK with durations), then `.\program-update-all.cmd -Health -RegisterSchedule`, `Get-ScheduledTask PcKeeperHealthCheck | Select -Expand Actions`, `Start-ScheduledTask PcKeeperHealthCheck`, wait for completion, check `latest.txt` updated and today's JSON written.
- [ ] **Step 6: Commit** — `git commit -am "feat(health): -Health entry point, schedule and menu item"`
