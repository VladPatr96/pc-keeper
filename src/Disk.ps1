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

function Get-DiskMeasureRoots {
    # Expand: every child folder is measured on its own (user data grows here and
    # a new consumer must show up by name). Fixed: measured as one folder each.
    [pscustomobject]@{
        Expand = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData)
        Fixed = @(
            (Join-Path $env:WINDIR 'WinSxS')
            (Join-Path $env:WINDIR 'Installer')
            $env:ProgramFiles
            ${env:ProgramFiles(x86)}
        )
    }
}

function New-DiskSnapshot {
    param(
        [Parameter(Mandatory)] [datetime] $Date,
        [Parameter(Mandatory)] [double] $FreeBytes,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Folders
    )

    [pscustomobject]@{
        Date = $Date.ToString('yyyy-MM-dd')
        FreeBytes = $FreeBytes
        Folders = @($Folders | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Bytes = [double] $_.Bytes } })
    }
}

function Compare-DiskSnapshots {
    param(
        [Parameter(Mandatory)] [object] $Current,
        [AllowNull()] [object] $Previous,
        [double] $MinGrowthBytes = 100MB
    )

    if (-not $Previous) {
        return @()
    }

    $before = @{}
    foreach ($folder in @($Previous.Folders)) { $before[$folder.Path] = [double] $folder.Bytes }

    @($Current.Folders) |
        ForEach-Object {
            $was = if ($before.ContainsKey($_.Path)) { $before[$_.Path] } else { 0 }
            [pscustomobject]@{ Path = $_.Path; Bytes = [double] $_.Bytes; GrowthBytes = [double] $_.Bytes - $was }
        } |
        Where-Object { $_.GrowthBytes -ge $MinGrowthBytes } |
        Sort-Object GrowthBytes -Descending
}

function Select-DiskBaseline {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots,
        [datetime] $Date = (Get-Date),
        [int] $DaysBack = 1
    )

    $cutoff = $Date.Date.AddDays(-$DaysBack)
    $Snapshots |
        Where-Object { ([datetime] $_.Date).Date -le $cutoff } |
        Sort-Object { [datetime] $_.Date } |
        Select-Object -Last 1
}

function Get-DiskDataDirectory {
    # History stays on D: drive C is the one that runs out of space.
    'D:\pc-keeper-data\disk'
}

function Save-DiskSnapshot {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [object] $Snapshot
    )

    New-Item -ItemType Directory -Force $Directory | Out-Null
    $path = Join-Path $Directory "$($Snapshot.Date).json"
    ConvertTo-Json -InputObject $Snapshot -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8
}

function Read-DiskSnapshots {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    Get-ChildItem -LiteralPath $Directory -Filter '????-??-??.json' |
        Sort-Object Name |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
}

function Format-DiskGrowthLine {
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [object[]] $Growth
    )

    $items = @($Growth | Select-Object -First 3 | ForEach-Object {
        "$(Split-Path $_.Path -Leaf) +$(ConvertTo-HumanSize -Bytes $_.GrowthBytes)"
    })
    "${Label}: $($items -join ', ')"
}

function Format-DiskNotification {
    param(
        [Parameter(Mandatory)] [double] $FreeBytes,
        [double] $ThresholdBytes = 15GB,
        [object[]] $DayGrowth = @(),
        [object[]] $WeekGrowth = @(),
        [object[]] $OffloadResults = @(),
        [object[]] $CleanupFailures = @()
    )

    $lines = @()
    foreach ($r in @($OffloadResults | Where-Object Status -eq 'Failed')) {
        $lines += "move $($r.Key) failed: $($r.Detail)"
    }
    foreach ($f in @($CleanupFailures)) {
        $lines += "cleanup failed: $($f.Path)"
    }
    $problems = $lines.Count
    foreach ($r in @($OffloadResults | Where-Object { $_.MovedAside })) {
        $lines += "old copy moved aside: $($r.MovedAside)"
    }

    $low = $FreeBytes -lt $ThresholdBytes
    if ($low) {
        if (@($DayGrowth).Count) { $lines += Format-DiskGrowthLine -Label 'grew since yesterday' -Growth $DayGrowth }
        if (@($WeekGrowth).Count) { $lines += Format-DiskGrowthLine -Label 'grew in a week' -Growth $WeekGrowth }
    }

    if (-not $low -and $lines.Count -eq 0) {
        return $null
    }

    $title = if ($low) {
        "PC Keeper: only $(ConvertTo-HumanSize -Bytes $FreeBytes) free on C"
    }
    elseif ($problems) {
        'PC Keeper: disk maintenance problem'
    }
    else {
        'PC Keeper: disk maintenance note'
    }

    [pscustomobject]@{ Title = $title; Lines = @($lines | Select-Object -First 4) }
}

function ConvertTo-DiskReportText {
    param(
        [Parameter(Mandatory)] [double] $FreeBeforeBytes,
        [Parameter(Mandatory)] [double] $FreeAfterBytes,
        [double] $CleanedBytes = 0,
        [object[]] $OffloadResults = @(),
        [object[]] $DayGrowth = @(),
        [object[]] $WeekGrowth = @(),
        [object[]] $CleanupFailures = @()
    )

    $builder = [Text.StringBuilder]::new()
    [void] $builder.AppendLine("PC Keeper Disk - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void] $builder.AppendLine('')
    [void] $builder.AppendLine("Free on C: $(ConvertTo-HumanSize -Bytes $FreeBeforeBytes) -> $(ConvertTo-HumanSize -Bytes $FreeAfterBytes)")
    [void] $builder.AppendLine("Cleaned: $(ConvertTo-HumanSize -Bytes $CleanedBytes)")
    foreach ($f in @($CleanupFailures)) {
        [void] $builder.AppendLine("  [Failed] cleanup $($f.Path) $($f.Error)")
    }

    [void] $builder.AppendLine('')
    [void] $builder.AppendLine('Offload to D:')
    # Already-moved and missing targets are the normal state; list only what happened.
    foreach ($r in @($OffloadResults | Where-Object { $_.Action -notin 'SkipLinked', 'SkipMissing' })) {
        $size = if ($r.Bytes) { ConvertTo-HumanSize -Bytes $r.Bytes } else { '' }
        $line = (@("  [$($r.Status)]", $r.Key, $r.Action, $size, $r.Detail, $r.MovedAside) | Where-Object { $_ }) -join ' '
        [void] $builder.AppendLine($line)
    }

    foreach ($section in @(@{ Label = 'Grew since yesterday'; Items = $DayGrowth }, @{ Label = 'Grew in a week'; Items = $WeekGrowth })) {
        [void] $builder.AppendLine('')
        [void] $builder.AppendLine("$($section.Label):")
        foreach ($g in @($section.Items | Select-Object -First 10)) {
            [void] $builder.AppendLine("  $(Split-Path $g.Path -Leaf) +$(ConvertTo-HumanSize -Bytes $g.GrowthBytes)  ($($g.Path), now $(ConvertTo-HumanSize -Bytes $g.Bytes))")
        }
    }

    $builder.ToString()
}

function Select-DiskMeasureFolders {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Children,
        [Parameter(Mandatory)] [string[]] $Expand
    )

    # A child that is (or contains) an expanded root is measured through that
    # root's children instead, otherwise e.g. AppData would count twice.
    $Children | Where-Object {
        $child = $_
        -not ($Expand | Where-Object { $_ -eq $child -or $_.StartsWith($child + '\', [StringComparison]::OrdinalIgnoreCase) })
    }
}

$script:DiskSizeScannerSource = @'
using System;
using System.IO;
public static class PcKeeperDiskSize {
    public static long Of(string root) {
        var options = new EnumerationOptions {
            RecurseSubdirectories = true, IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint };
        long total = 0;
        try {
            foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", options)) {
                try { total += f.Length; } catch { }
            }
        } catch { }
        return total;
    }
}
'@

function Measure-DiskFolders {
    param(
        [object] $Roots = (Get-DiskMeasureRoots)
    )

    if (-not ('PcKeeperDiskSize' -as [type])) {
        Add-Type -TypeDefinition $script:DiskSizeScannerSource -Language CSharp
    }

    # Junctions are skipped: data already moved to D must not count against C.
    $folders = @()
    foreach ($root in @($Roots.Expand | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        $children = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Select-Object -ExpandProperty FullName)
        $folders += @(Select-DiskMeasureFolders -Children $children -Expand $Roots.Expand)
    }
    $folders += @($Roots.Fixed | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

    foreach ($path in ($folders | Sort-Object -Unique)) {
        [pscustomobject]@{ Path = $path; Bytes = [double] [PcKeeperDiskSize]::Of($path) }
    }
}

function Get-DriveFreeBytes {
    [double] (Get-PSDrive -Name C).Free
}

function Invoke-DiskMaintenance {
    param(
        [switch] $Quiet,
        [switch] $DryRun
    )

    $dir = Get-DiskDataDirectory
    $freeBefore = Get-DriveFreeBytes
    $cleanupFailures = @()
    $cleaned = 0
    $offload = @()

    try {
        foreach ($candidate in @(Get-DailyCleanupTargets)) {
            if (-not $Quiet) { Write-Host "cleanup: $($candidate.Name)" }
            $failed = @(Invoke-CleanupCandidate -Candidate $candidate -DryRun:$DryRun)
            $cleanupFailures += $failed
            if ($failed.Count -eq 0) { $cleaned += $candidate.SizeBytes }
        }
        if (-not $DryRun) {
            Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $cleanupFailures += [pscustomobject]@{ Path = 'cleanup step'; Error = $_.Exception.Message }
    }

    foreach ($target in @(Get-OffloadTargets)) {
        if (-not $Quiet) { Write-Host "offload: $($target.Key)" }
        $offload += Invoke-Offload -Target $target -DryRun:$DryRun
    }

    if (-not $Quiet) { Write-Host 'measuring folders on C...' }
    $snapshot = New-DiskSnapshot -Date (Get-Date) -FreeBytes (Get-DriveFreeBytes) -Folders @(Measure-DiskFolders)
    $history = @(Read-DiskSnapshots -Directory $dir)
    $dayGrowth = @(Compare-DiskSnapshots -Current $snapshot -Previous (Select-DiskBaseline -Snapshots $history -DaysBack 1))
    $weekGrowth = @(Compare-DiskSnapshots -Current $snapshot -Previous (Select-DiskBaseline -Snapshots $history -DaysBack 7) -MinGrowthBytes 500MB)

    $report = ConvertTo-DiskReportText -FreeBeforeBytes $freeBefore -FreeAfterBytes $snapshot.FreeBytes -CleanedBytes $cleaned `
        -OffloadResults $offload -DayGrowth $dayGrowth -WeekGrowth $weekGrowth -CleanupFailures $cleanupFailures
    if (-not $DryRun) {
        Save-DiskSnapshot -Directory $dir -Snapshot $snapshot
        $report | Set-Content -LiteralPath (Join-Path $dir 'latest.txt') -Encoding utf8
    }

    $toast = Format-DiskNotification -FreeBytes $snapshot.FreeBytes -DayGrowth $dayGrowth -WeekGrowth $weekGrowth `
        -OffloadResults $offload -CleanupFailures $cleanupFailures
    if ($toast) {
        Show-HealthToast -Title $toast.Title -Lines $toast.Lines
    }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host $report
    }
}

function New-DiskScheduleAction {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    [pscustomobject]@{
        Execute = 'C:\Windows\System32\conhost.exe'
        Argument = "--headless pwsh -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Maintain -Quiet"
    }
}

function Register-DiskSchedule {
    param(
        # Register from the main checkout: a worktree path disappears after merge.
        [string] $ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'program-update-all.ps1')
    )

    $spec = New-DiskScheduleAction -ScriptPath $ScriptPath
    $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
    $daily = New-ScheduledTaskTrigger -Daily -At '13:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'PcKeeperDiskMaintenance' -Action $action -Trigger $daily -Settings $settings -Description 'PC Keeper: daily cleanup, offload to D and measure of drive C' -Force | Out-Null
    Write-Host "Registered scheduled task PcKeeperDiskMaintenance (daily 13:00). Report: $(Join-Path (Get-DiskDataDirectory) 'latest.txt')"

    $old = 'DiskMaintenance-C-Offload'
    if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
        try {
            Disable-ScheduledTask -TaskName $old -ErrorAction Stop | Out-Null
            Write-Host "Disabled the old task $old (disk-tools)."
        }
        catch {
            Write-Warning "Could not disable $old ($($_.Exception.Message)). Disable it from an elevated terminal: Disable-ScheduledTask -TaskName $old"
        }
    }
}

function Get-DiskActionCatalog {
    # Manual actions from disk-tools (free-c-admin, cleanup-ab, move-caches):
    # offered in the Cleanup menu, never run by the daily task.
    @(
        @{ Id = 'pagefile'; Name = 'Move the page file to D (1 GB stays on C, needs reboot)'; Path = 'C:\pagefile.sys'; Admin = $true }
        @{ Id = 'winsxs'; Name = 'Clean the Windows component store (DISM StartComponentCleanup)'; Path = (Join-Path $env:WINDIR 'WinSxS'); Admin = $true }
        @{ Id = 'iobit'; Name = 'Remove IObit Driver Booster leftovers and its scheduled tasks'; Path = (Join-Path $env:ProgramData 'IObit'); Admin = $true }
        @{ Id = 'bluestacks'; Name = 'Remove BlueStacks leftovers'; Path = (Join-Path $env:ProgramFiles 'BlueStacks_nxt'); Admin = $true }
        @{ Id = 'app-leftovers'; Name = 'Uninstall Auto-Claude and Aperant'; Path = (Join-Path $env:LOCALAPPDATA 'Programs'); Admin = $false }
        @{ Id = 'paperclip'; Name = 'Remove Paperclip instances'; Path = (Join-Path $env:USERPROFILE '.paperclip\instances'); Admin = $false }
        @{ Id = 'dev-caches'; Name = 'Keep npm and pip caches on D (D:\dev-cache)'; Path = 'D:\dev-cache'; Admin = $false }
    ) | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Path = $_.Path; RequiresAdmin = $_.Admin; RiskLevel = 'Review' }
    }
}

function ConvertTo-DiskActionCandidate {
    param(
        [Parameter(Mandatory)] [object] $Action
    )

    New-CleanupCandidate -Category 'Disk action' -Name $Action.Name -Paths @($Action.Path) -RiskLevel $Action.RiskLevel -RequiresAdmin $Action.RequiresAdmin -ActionId $Action.Id
}

function Get-AppLeftoverUninstallers {
    @(
        (Join-Path $env:LOCALAPPDATA 'Programs\auto-claude-ui\Uninstall Auto-Claude.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\aperant\Uninstall Aperant.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

function Get-IObitTaskNames {
    @('Driver Booster Scheduler', 'Driver Booster SkipUAC (user)', 'Driver Booster Update') |
        Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }
}

function Test-DiskActionApplicable {
    param(
        [Parameter(Mandatory)] [string] $Id
    )

    switch ($Id) {
        'pagefile' { -not (Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'D:*' }) }
        'winsxs' { $true }
        'iobit' { (Test-Path -LiteralPath (Join-Path $env:ProgramData 'IObit')) -or @(Get-IObitTaskNames).Count -gt 0 }
        'bluestacks' { (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'BlueStacks_nxt')) -or (Test-Path -LiteralPath (Join-Path $env:ProgramData 'BlueStacks_nxt')) }
        'app-leftovers' { @(Get-AppLeftoverUninstallers).Count -gt 0 }
        'paperclip' { Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.paperclip\instances') }
        'dev-caches' { (Test-Path -LiteralPath 'D:\') -and ($env:PIP_CACHE_DIR -notlike 'D:*' -or -not ((Invoke-NativeText -FilePath 'npm' -Arguments @('config', 'get', 'cache') -TimeoutSeconds 30).StdOut.Trim() -like 'D:*')) }
        default { $false }
    }
}

function Get-DiskActionTargets {
    foreach ($action in Get-DiskActionCatalog) {
        $applicable = try { Test-DiskActionApplicable -Id $action.Id } catch { $false }
        if ($applicable) {
            ConvertTo-DiskActionCandidate -Action $action
        }
    }
}

function Invoke-DiskAction {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $DryRun
    )

    if ($DryRun) {
        Write-Host "DRY RUN disk action $Id"
        return @()
    }

    try {
        switch ($Id) {
            'pagefile' {
                # Create the page file on D first and shrink C only after that, so the
                # system is never left without a page file.
                $cs = Get-CimInstance Win32_ComputerSystem
                if ($cs.AutomaticManagedPagefile) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
                }
                if (-not (Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like 'D:*' })) {
                    New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'D:\pagefile.sys'; InitialSize = [uint32] 0; MaximumSize = [uint32] 0 } -ErrorAction Stop | Out-Null
                }
                $onC = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like 'C:*' }
                if ($onC) {
                    Set-CimInstance -InputObject $onC -Property @{ InitialSize = [uint32] 1024; MaximumSize = [uint32] 1024 } -ErrorAction Stop
                }
                Write-Host 'Page file moved to D; takes effect after a reboot.'
            }
            'winsxs' {
                $result = Invoke-NativeText -FilePath 'dism.exe' -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -TimeoutSeconds 3600
                if ($result.TimedOut -or $result.ExitCode -ne 0) {
                    throw "DISM exit $($result.ExitCode): $($result.Text.Trim())"
                }
            }
            'iobit' {
                Remove-Item -LiteralPath (Join-Path $env:ProgramData 'IObit'), (Join-Path $env:APPDATA 'IObit') -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($task in Get-IObitTaskNames) {
                    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
                }
            }
            'bluestacks' {
                Remove-Item -LiteralPath (Join-Path $env:ProgramFiles 'BlueStacks_nxt'), (Join-Path $env:ProgramData 'BlueStacks_nxt') -Recurse -Force -ErrorAction SilentlyContinue
            }
            'app-leftovers' {
                foreach ($uninstaller in Get-AppLeftoverUninstallers) {
                    Start-Process -FilePath $uninstaller -ArgumentList '/currentuser', '/S' -Wait
                }
            }
            'paperclip' {
                Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.paperclip\instances') -Recurse -Force -ErrorAction Stop
            }
            'dev-caches' {
                New-Item -ItemType Directory -Force 'D:\dev-cache\npm-cache', 'D:\dev-cache\pip-cache' | Out-Null
                Invoke-NativeText -FilePath 'npm' -Arguments @('config', 'set', 'cache', 'D:\dev-cache\npm-cache') -TimeoutSeconds 60 | Out-Null
                [Environment]::SetEnvironmentVariable('PIP_CACHE_DIR', 'D:\dev-cache\pip-cache', 'User')
                $env:PIP_CACHE_DIR = 'D:\dev-cache\pip-cache'
            }
            default { throw "unknown disk action: $Id" }
        }
        @()
    }
    catch {
        Write-Warning "Disk action $Id failed: $($_.Exception.Message)"
        @([pscustomobject]@{ Path = $Id; Error = $_.Exception.Message })
    }
}
