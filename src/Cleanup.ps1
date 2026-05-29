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
        [bool] $RequiresClosedApp = $false
    )

    [pscustomobject]@{
        Category = $Category
        Name = $Name
        Paths = $Paths
        SizeBytes = $SizeBytes
        RiskLevel = $RiskLevel
        RequiresAdmin = $RequiresAdmin
        RequiresClosedApp = $RequiresClosedApp
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
    ) | Where-Object { $_ }
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
    )
}

function Invoke-CleanupCandidate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [switch] $DryRun
    )

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
            if (Test-Path -LiteralPath $path -PathType Container) {
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
    $targets = @(Show-Spinner -Message 'Scanning cleanup targets...' -ScriptBlock { Get-CleanupTargets })
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
