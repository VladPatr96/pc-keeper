# Disk.ps1 — unattended care of drive C: daily measure, cleanup, offload of
# heavy data folders to D (junction left behind) and a toast when space runs
# low or a step fails. Pure resolvers/formatters are tested; the executors that
# touch files, robocopy or Task Scheduler stay thin and untested.

function Get-OffloadTargets {
    param(
        [string] $Destination = 'D:\c-offload'
    )

    # orca is not here: its growth was a leak of Codex marketplace clones, which
    # the daily cleanup removes (Get-DailyCleanupPlan).
    @(
        @{ Key = 'claude-vm'; Source = Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\vm_bundles'; Procs = @('Claude', 'claude') }
        @{ Key = 'codex'; Source = Join-Path $env:USERPROFILE '.codex'; Procs = @('codex') }
        @{ Key = 'playwright'; Source = Join-Path $env:LOCALAPPDATA 'ms-playwright'; Procs = @() }
        @{ Key = 'perplexity'; Source = Join-Path $env:LOCALAPPDATA 'Perplexity'; Procs = @('Comet', 'Perplexity') }
        @{ Key = 'dot-cache'; Source = Join-Path $env:USERPROFILE '.cache'; Procs = @() }
        @{ Key = 'github-desk'; Source = Join-Path $env:LOCALAPPDATA 'GitHubDesktop'; Procs = @('GitHubDesktop') }
        @{ Key = 'grok'; Source = Join-Path $env:USERPROFILE '.grok'; Procs = @() }
        @{ Key = 'rustup'; Source = Join-Path $env:USERPROFILE '.rustup'; Procs = @() }
        @{ Key = 'gemini'; Source = Join-Path $env:USERPROFILE '.gemini'; Procs = @() }
        @{ Key = 'u2net'; Source = Join-Path $env:USERPROFILE '.u2net'; Procs = @() }
        @{ Key = 'antigravity'; Source = Join-Path $env:USERPROFILE '.antigravity-ide'; Procs = @('Antigravity') }
        @{ Key = 'vscode-ext'; Source = Join-Path $env:USERPROFILE '.vscode\extensions'; Procs = @('Code') }
        @{ Key = 'vscode-srv'; Source = Join-Path $env:USERPROFILE '.vscode-server'; Procs = @('Code') }
        @{ Key = 'chrome'; Source = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'; Procs = @('chrome') }
        @{ Key = 'edge'; Source = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'; Procs = @('msedge') }
        @{ Key = 'downloads'; Source = Join-Path $env:USERPROFILE 'Downloads'; Procs = @() }
    ) | ForEach-Object {
        [pscustomobject]@{
            Key = $_.Key
            Source = $_.Source
            Target = Join-Path $Destination $_.Key
            Procs = $_.Procs
        }
    }
}

function Resolve-OffloadAction {
    param(
        [Parameter(Mandatory)] [bool] $SourceExists,
        [Parameter(Mandatory)] [bool] $SourceIsLink,
        [Parameter(Mandatory)] [bool] $TargetExists,
        [string[]] $BusyProcesses = @()
    )

    if (-not $SourceExists) { return 'SkipMissing' }
    if ($SourceIsLink) { return 'SkipLinked' }
    if ($BusyProcesses.Count -gt 0) { return 'SkipBusy' }
    # A copy on D without a junction on C is a leftover of an interrupted move:
    # the live data is on C, so the old copy is moved aside, never merged or trusted.
    if ($TargetExists) { return 'MoveStaleThenOffload' }
    'Offload'
}

function Get-StaleOffloadPath {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [datetime] $Date = (Get-Date),
        [string[]] $ExistingPaths = @()
    )

    $base = "$Target-stale-$($Date.ToString('yyyy-MM-dd'))"
    $path = $base
    $n = 2
    while ($ExistingPaths -contains $path) {
        $path = "$base-$n"
        $n++
    }
    $path
}

function Test-OffloadCopyMatches {
    param(
        [Parameter(Mandatory)] [long] $SourceCount,
        [Parameter(Mandatory)] [double] $SourceBytes,
        [Parameter(Mandatory)] [long] $TargetCount,
        [Parameter(Mandatory)] [double] $TargetBytes
    )

    $SourceCount -eq $TargetCount -and $SourceBytes -eq $TargetBytes
}

function New-OffloadResult {
    param(
        [Parameter(Mandatory)] [object] $Target,
        [Parameter(Mandatory)] [ValidateSet('OK', 'Skipped', 'Failed')] [string] $Status,
        [string] $Action = '',
        [double] $Bytes = 0,
        [string] $Detail = '',
        [string] $MovedAside = ''
    )

    [pscustomobject]@{
        Key = $Target.Key
        Status = $Status
        Action = $Action
        Bytes = $Bytes
        Detail = $Detail
        MovedAside = $MovedAside
    }
}

function Get-FolderFileStats {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -Attributes !ReparsePoint -ErrorAction SilentlyContinue)
    $bytes = if ($files.Count) { [double](($files | Measure-Object Length -Sum).Sum) } else { 0 }
    [pscustomobject]@{ Count = [long] $files.Count; Bytes = $bytes }
}

function Invoke-Offload {
    param(
        [Parameter(Mandatory)] [object] $Target,
        [switch] $DryRun
    )

    $src = $Target.Source
    $tgt = $Target.Target
    $sourceExists = Test-Path -LiteralPath $src
    $isLink = $sourceExists -and [bool] (Get-Item -LiteralPath $src -Force).LinkType
    $busy = @($Target.Procs | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    $action = Resolve-OffloadAction -SourceExists $sourceExists -SourceIsLink $isLink -TargetExists (Test-Path -LiteralPath $tgt) -BusyProcesses $busy

    switch ($action) {
        'SkipMissing' { return New-OffloadResult -Target $Target -Status 'Skipped' -Action $action }
        'SkipLinked' { return New-OffloadResult -Target $Target -Status 'Skipped' -Action $action }
        'SkipBusy' { return New-OffloadResult -Target $Target -Status 'Skipped' -Action $action -Detail "close first: $($busy -join ', ')" }
    }

    $stats = Get-FolderFileStats -Path $src
    if ($DryRun) {
        return New-OffloadResult -Target $Target -Status 'Skipped' -Action $action -Bytes $stats.Bytes -Detail 'dry run'
    }

    $movedAside = ''
    try {
        if ($action -eq 'MoveStaleThenOffload') {
            $existing = @(Get-ChildItem -LiteralPath (Split-Path $tgt -Parent) -Directory -Force | Select-Object -ExpandProperty FullName)
            $movedAside = Get-StaleOffloadPath -Target $tgt -ExistingPaths $existing
            Rename-Item -LiteralPath $tgt -NewName (Split-Path $movedAside -Leaf) -ErrorAction Stop
        }

        New-Item -ItemType Directory -Force (Split-Path $tgt -Parent) | Out-Null
        $copy = Invoke-NativeText -FilePath 'robocopy.exe' -Arguments @($src, $tgt, '/E', '/R:2', '/W:2', '/XJ', '/NP', '/NFL', '/NDL') -TimeoutSeconds 7200
        if ($copy.TimedOut -or $copy.ExitCode -ge 8) {
            Remove-Item -LiteralPath $tgt -Recurse -Force -ErrorAction SilentlyContinue
            return New-OffloadResult -Target $Target -Status 'Failed' -Action $action -MovedAside $movedAside -Detail "robocopy failed (exit $($copy.ExitCode)), source untouched"
        }

        $copied = Get-FolderFileStats -Path $tgt
        if (-not (Test-OffloadCopyMatches -SourceCount $stats.Count -SourceBytes $stats.Bytes -TargetCount $copied.Count -TargetBytes $copied.Bytes)) {
            Remove-Item -LiteralPath $tgt -Recurse -Force -ErrorAction SilentlyContinue
            return New-OffloadResult -Target $Target -Status 'Failed' -Action $action -MovedAside $movedAside -Detail "copy mismatch ($($copied.Count)/$($stats.Count) files), source untouched"
        }

        # Rename first: it fails as a whole when any file is locked, so the source
        # is never left half-deleted (the old script deleted in place).
        $old = "$src.pc-keeper-old"
        try {
            Rename-Item -LiteralPath $src -NewName (Split-Path $old -Leaf) -ErrorAction Stop
        }
        catch {
            Remove-Item -LiteralPath $tgt -Recurse -Force -ErrorAction SilentlyContinue
            return New-OffloadResult -Target $Target -Status 'Failed' -Action $action -MovedAside $movedAside -Detail "source is in use, not moved: $($_.Exception.Message)"
        }

        try {
            New-Item -ItemType Junction -Path $src -Target $tgt -ErrorAction Stop | Out-Null
        }
        catch {
            Rename-Item -LiteralPath $old -NewName (Split-Path $src -Leaf) -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tgt -Recurse -Force -ErrorAction SilentlyContinue
            return New-OffloadResult -Target $Target -Status 'Failed' -Action $action -MovedAside $movedAside -Detail "junction not created, source restored: $($_.Exception.Message)"
        }

        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        $detail = if (Test-Path -LiteralPath $old) { "moved; delete leftover $old by hand" } else { '' }
        New-OffloadResult -Target $Target -Status 'OK' -Action $action -Bytes $stats.Bytes -MovedAside $movedAside -Detail $detail
    }
    catch {
        New-OffloadResult -Target $Target -Status 'Failed' -Action $action -MovedAside $movedAside -Detail $_.Exception.Message
    }
}
