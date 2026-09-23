# Cleanup.ps1 — the "Cleanup" pillar. Scanners find junk, the checklist
# confirms, and deletion runs only against whitelisted paths. Deletion is
# dry-run by default. Pure helpers (whitelist guard, size math) are tested;
# the scanners and the deleter are thin wrappers.

function New-CleanupCandidate {
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Paths,
        [double] $SizeBytes = 0,
        [ValidateSet('Safe', 'Review')] [string] $RiskLevel = 'Safe',
        [bool] $RequiresAdmin = $false,
        [bool] $RequiresClosedApp = $false,
        # Remove the path itself (a stale clone, an old version), not just its contents.
        [bool] $RemoveSelf = $false,
        # A system change instead of a deletion (pagefile, DISM); see Invoke-DiskAction.
        [string] $ActionId = ''
    )

    [pscustomobject]@{
        Category = $Category
        Name = $Name
        Paths = $Paths
        SizeBytes = $SizeBytes
        RiskLevel = $RiskLevel
        RequiresAdmin = $RequiresAdmin
        RequiresClosedApp = $RequiresClosedApp
        RemoveSelf = $RemoveSelf
        ActionId = $ActionId
        Selected = $false
    }
}

function Get-CleanupSafeRoots {
    @(
        $env:TEMP
        $env:TMP
        (Join-Path $env:WINDIR 'Temp')
        (Join-Path $env:LOCALAPPDATA 'npm-cache')
        (Join-Path $env:LOCALAPPDATA 'pnpm-cache')
        (Join-Path $env:APPDATA 'npm-cache')
        (Join-Path $env:LOCALAPPDATA 'pip\cache')
        (Join-Path $env:ProgramData 'chocolatey\lib-bad')
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache')
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Code Cache')
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\GPUCache')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Code Cache')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\GPUCache')
        (Join-Path $env:LOCALAPPDATA 'SquirrelTemp')
        (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        'C:\tmp'
        (Join-Path $env:APPDATA 'Code\CachedExtensionVSIXs')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')
        (Join-Path $env:LOCALAPPDATA 'auto-claude-ui-updater')
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin')
        (Get-CodexStagingDirectories)
        (Get-NpmGlobalScopeDirectories)
    ) | Where-Object { $_ }
}

function Get-CodexStagingDirectories {
    # Codex clones its plugin marketplace here on every upgrade attempt and never
    # removes the clone; orca embeds its own Codex home with the same leak.
    @(
        (Join-Path $env:USERPROFILE '.codex')
        (Join-Path $env:APPDATA 'orca\codex-runtime-home\home')
    ) | ForEach-Object { Join-Path $_ '.tmp\marketplaces\.staging' }
}

function Get-NpmGlobalScopeDirectories {
    # npm i -g unpacks into "<scope>\.<name>-<suffix>" and renames it; an interrupted
    # install leaves the dot-folder behind.
    @('@openai', '@anthropic-ai', '@google') | ForEach-Object { Join-Path $env:APPDATA "npm\node_modules\$_" }
}

function Select-StaleDirectories {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items,
        [Parameter(Mandatory)] [string] $Pattern,
        [int] $OlderThanHours = 2,
        [datetime] $Now = (Get-Date)
    )

    $cutoff = $Now.AddHours(-$OlderThanHours)
    $Items | Where-Object { $_.Name -like $Pattern -and $_.LastWriteTime -lt $cutoff }
}

function Select-OldVersionDirectories {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items
    )

    $Items | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1
}

function Test-IsSafeCleanupPath {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [string[]] $SafeRoots = (Get-CleanupSafeRoots)
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch {
        return $false
    }

    # A bare drive root such as "C:" must never be cleanable.
    if ($full -match '^[A-Za-z]:$') {
        return $false
    }

    foreach ($root in $SafeRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        try {
            $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        }
        catch {
            continue
        }

        if ($full.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($full.StartsWith($normalizedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $false
}

function Get-SelectedCleanupSize {
    param(
        [object[]] $Candidates = @()
    )

    $selected = @($Candidates | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) {
        return 0
    }

    $sum = ($selected | Measure-Object -Property SizeBytes -Sum).Sum
    if ($null -eq $sum) {
        return 0
    }

    $sum
}

function Get-PathSizeBytes {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path $Path)) {
        return 0
    }

    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            return 0
        }
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) {
            return 0
        }
        return [double]$sum
    }
    catch {
        return 0
    }
}

function Get-TempCleanupTargets {
    $candidates = @()

    $tempLocations = @(
        @{ Name = 'User temp (%TEMP%)'; Path = $env:TEMP; Admin = $false }
        @{ Name = 'Windows temp'; Path = (Join-Path $env:WINDIR 'Temp'); Admin = $true }
        @{ Name = 'npm cache'; Path = (Join-Path $env:LOCALAPPDATA 'npm-cache'); Admin = $false }
        @{ Name = 'pnpm cache'; Path = (Join-Path $env:LOCALAPPDATA 'pnpm-cache'); Admin = $false }
        @{ Name = 'pip cache'; Path = (Join-Path $env:LOCALAPPDATA 'pip\cache'); Admin = $false }
    )

    foreach ($location in $tempLocations) {
        if (-not $location.Path -or -not (Test-Path $location.Path)) {
            continue
        }

        $candidates += New-CleanupCandidate `
            -Category 'Temp' `
            -Name $location.Name `
            -Paths @($location.Path) `
            -SizeBytes (Get-PathSizeBytes -Path $location.Path) `
            -RiskLevel 'Safe' `
            -RequiresAdmin $location.Admin
    }

    $candidates
}

function Get-BrowserCacheTargets {
    $candidates = @()

    $browsers = @(
        @{ Name = 'Chrome cache'; Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache') }
        @{ Name = 'Chrome code cache'; Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Code Cache') }
        @{ Name = 'Edge cache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache') }
        @{ Name = 'Edge code cache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Code Cache') }
    )

    foreach ($browser in $browsers) {
        if (-not $browser.Path -or -not (Test-Path $browser.Path)) {
            continue
        }

        $candidates += New-CleanupCandidate `
            -Category 'Browser cache' `
            -Name $browser.Name `
            -Paths @($browser.Path) `
            -SizeBytes (Get-PathSizeBytes -Path $browser.Path) `
            -RiskLevel 'Safe' `
            -RequiresClosedApp $true
    }

    $candidates
}

function Get-LargeOldFileRoots {
    # Only scan folders where real user content lives. Scanning the whole
    # profile (AppData, caches, node_modules) is slow and surfaces noise.
    @(
        (Join-Path $env:USERPROFILE 'Downloads')
        (Join-Path $env:USERPROFILE 'Desktop')
        (Join-Path $env:USERPROFILE 'Documents')
        (Join-Path $env:USERPROFILE 'Videos')
    ) | Where-Object { $_ -and (Test-Path $_) }
}

function Get-LargeOldFiles {
    param(
        [string[]] $Roots = (Get-LargeOldFileRoots),
        [double] $MinimumSizeBytes = 524288000,
        [int] $OlderThanDays = 180,
        [int] $Top = 20
    )

    $roots = @($Roots | Where-Object { $_ -and (Test-Path $_) })
    if ($roots.Count -eq 0) {
        return @()
    }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $found = foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $MinimumSizeBytes -and $_.LastWriteTime -lt $cutoff }
    }

    $files = @($found | Sort-Object Length -Descending | Select-Object -First $Top)
    foreach ($file in $files) {
        New-CleanupCandidate `
            -Category 'Large/old files' `
            -Name $file.FullName `
            -Paths @($file.FullName) `
            -SizeBytes ([double]$file.Length) `
            -RiskLevel 'Review'
    }
}

function Get-CleanupTargets {
    @(
        Get-TempCleanupTargets
        Get-BrowserCacheTargets
        Get-LargeOldFiles
        Get-DiskActionTargets
    )
}

function Split-CleanupCandidatesByPrivilege {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [bool] $IsAdmin
    )

    [pscustomobject]@{
        Runnable = @($Candidates | Where-Object { $IsAdmin -or -not $_.RequiresAdmin })
        Blocked = @($Candidates | Where-Object { -not $IsAdmin -and $_.RequiresAdmin })
    }
}

function New-DailyCleanupRule {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('Contents', 'Files', 'Stale', 'OldVersions')] [string] $Mode,
        [string] $Pattern = '',
        [string[]] $Procs = @()
    )

    [pscustomobject]@{ Name = $Name; Path = $Path; Mode = $Mode; Pattern = $Pattern; Procs = $Procs }
}

function Get-DailyCleanupPlan {
    # What the unattended daily run removes: junk apps recreate on their own.
    @(
        New-DailyCleanupRule -Name 'User temp' -Path $env:TEMP -Mode 'Contents'
        New-DailyCleanupRule -Name 'SquirrelTemp' -Path (Join-Path $env:LOCALAPPDATA 'SquirrelTemp') -Mode 'Contents'
        New-DailyCleanupRule -Name 'CrashDumps' -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps') -Mode 'Contents'
        New-DailyCleanupRule -Name 'C:\tmp' -Path 'C:\tmp' -Mode 'Contents'
        New-DailyCleanupRule -Name 'VS Code extension packages' -Path (Join-Path $env:APPDATA 'Code\CachedExtensionVSIXs') -Mode 'Contents'
        New-DailyCleanupRule -Name 'INetCache' -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') -Mode 'Contents'
        New-DailyCleanupRule -Name 'Explorer thumbnails' -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Mode 'Files' -Pattern 'thumbcache_*.db'
        New-DailyCleanupRule -Name 'auto-claude-ui-updater' -Path (Join-Path $env:LOCALAPPDATA 'auto-claude-ui-updater') -Mode 'Contents'
        foreach ($dir in Get-NpmGlobalScopeDirectories) {
            New-DailyCleanupRule -Name "npm staging $(Split-Path $dir -Leaf)" -Path $dir -Mode 'Stale' -Pattern '.*-*'
        }
        foreach ($dir in Get-CodexStagingDirectories) {
            New-DailyCleanupRule -Name 'Codex marketplace clones' -Path $dir -Mode 'Stale' -Pattern 'marketplace-upgrade-*'
        }
        New-DailyCleanupRule -Name 'Old Codex versions' -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Mode 'OldVersions' -Procs @('codex')
    )
}

function Get-DailyCleanupTargets {
    param(
        [object[]] $Plan = (Get-DailyCleanupPlan)
    )

    foreach ($rule in $Plan) {
        if (-not (Test-Path -LiteralPath $rule.Path)) {
            continue
        }

        $busy = @($rule.Procs | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
        if ($busy.Count -gt 0) {
            continue
        }

        switch ($rule.Mode) {
            'Contents' {
                New-CleanupCandidate -Category 'Daily' -Name $rule.Name -Paths @($rule.Path) -SizeBytes (Get-PathSizeBytes -Path $rule.Path)
            }
            'Files' {
                $files = @(Get-ChildItem -LiteralPath $rule.Path -Filter $rule.Pattern -File -Force -ErrorAction SilentlyContinue)
                if ($files.Count -gt 0) {
                    New-CleanupCandidate -Category 'Daily' -Name $rule.Name -Paths @($files.FullName) -SizeBytes ([double](($files | Measure-Object Length -Sum).Sum))
                }
            }
            default {
                $dirs = @(Get-ChildItem -LiteralPath $rule.Path -Directory -Force -ErrorAction SilentlyContinue)
                $picked = if ($rule.Mode -eq 'Stale') {
                    @(Select-StaleDirectories -Items $dirs -Pattern $rule.Pattern)
                }
                else {
                    @(Select-OldVersionDirectories -Items $dirs)
                }
                foreach ($dir in $picked) {
                    New-CleanupCandidate -Category 'Daily' -Name "$($rule.Name): $($dir.Name)" -Paths @($dir.FullName) -SizeBytes (Get-PathSizeBytes -Path $dir.FullName) -RemoveSelf $true
                }
            }
        }
    }
}

function Invoke-CleanupCandidate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [switch] $DryRun
    )

    if ($Candidate.ActionId) {
        return Invoke-DiskAction -Id $Candidate.ActionId -DryRun:$DryRun
    }

    $failures = @()
    foreach ($path in @($Candidate.Paths)) {
        if (-not (Test-IsSafeCleanupPath -Path $path)) {
            Write-Warning "Skipping path outside the cleanup whitelist: $path"
            $failures += [pscustomobject]@{ Path = $path; Error = 'Outside whitelist' }
            continue
        }

        if ($DryRun) {
            Write-Host "DRY RUN remove $path"
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            if ($Candidate.RemoveSelf) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $path -PathType Container) {
                Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "Failed to clean $path : $($_.Exception.Message)"
            $failures += [pscustomobject]@{ Path = $path; Error = $_.Exception.Message }
        }
    }

    $failures
}

function Format-CleanupCandidate {
    param(
        [Parameter(Mandatory)] [object] $Item
    )

    $size = ConvertTo-HumanSize -Bytes $Item.SizeBytes
    $flags = @()
    if ($Item.RiskLevel -eq 'Review') { $flags += 'review' }
    if ($Item.RequiresClosedApp) { $flags += 'close app first' }
    if ($Item.RequiresAdmin) { $flags += 'admin' }
    $suffix = if ($flags.Count -gt 0) { " ({0})" -f ($flags -join ', ') } else { '' }

    "[$($Item.Category)] $($Item.Name) - $size$suffix"
}

function Invoke-CleanupFlow {
    param(
        [switch] $DryRun
    )

    Clear-Host
    $all = @(Show-Spinner -Message 'Scanning cleanup targets...' -ScriptBlock { Get-CleanupTargets })
    $split = Split-CleanupCandidatesByPrivilege -Candidates $all -IsAdmin (Test-IsAdministrator)
    if ($split.Blocked.Count -gt 0) {
        Write-Host 'Needs an elevated terminal (re-run PC Keeper as administrator):'
        foreach ($item in $split.Blocked) {
            Write-Host "  $(Format-CleanupCandidate -Item $item)"
        }
        Write-Host ''
        [void] (Read-Host 'Press Enter to continue')
    }

    $targets = @($split.Runnable)
    if ($targets.Count -eq 0) {
        Write-Host 'Nothing to clean.'
        return
    }

    $selected = @(Invoke-ChecklistMenu -Items $targets -Title 'Cleanup (Space toggles, Enter confirms)' -ItemFormatter { param($Item) Format-CleanupCandidate -Item $Item })
    if ($selected.Count -eq 0) {
        Write-Host 'Nothing selected.'
        return
    }

    $size = Get-SelectedCleanupSize -Candidates $selected
    Write-Host ''
    Write-StatusLine -Status 'Info' -Label 'About to free' -Value (ConvertTo-HumanSize -Bytes $size)

    if (-not $DryRun) {
        $answer = Read-Host "Delete $($selected.Count) selected item(s)? Type Y to continue"
        if ($answer -ne 'Y') {
            Write-Host 'Cancelled.'
            return
        }
    }

    $failures = @()
    foreach ($candidate in $selected) {
        $failures += Invoke-CleanupCandidate -Candidate $candidate -DryRun:$DryRun
    }

    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "$($failures.Count) item(s) could not be removed:"
        $failures | Format-Table -AutoSize
    }
    else {
        Write-Host 'Cleanup complete.'
    }
}

function Show-CleanupSummary {
    param(
        [Parameter(Mandatory)] [object[]] $Candidates
    )

    Write-Header -Title 'Cleanup' -Subtitle 'Reclaimable space by category'
    Write-Host ''
    foreach ($candidate in $Candidates) {
        $status = if ($candidate.RiskLevel -eq 'Review') { 'Warn' } else { 'Info' }
        $value = ConvertTo-HumanSize -Bytes $candidate.SizeBytes
        Write-StatusLine -Status $status -Label "[$($candidate.Category)] $($candidate.Name)" -Value $value
    }

    $total = if ($Candidates.Count -gt 0) { ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum } else { 0 }
    if ($null -eq $total) { $total = 0 }
    Write-Host ''
    Write-StatusLine -Status 'Info' -Label 'Total reclaimable' -Value (ConvertTo-HumanSize -Bytes $total)
}
