# Security.ps1 — the "Security" pillar. Reports settings-hygiene and account
# findings, and can apply admin-gated fixes (dry-run by default). Pure helpers
# (model, toggle classifier, score) are tested; scanners and the fixer that
# touch the system are thin wrappers.

function New-SecurityFinding {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('Ok', 'Warn', 'Bad', 'Info')] [string] $Status,
        [Parameter(Mandatory)] [string] $Title,
        [string] $Detail = '',
        [string] $FixCommand = '',
        [string[]] $FixArguments = @(),
        [bool] $RequiresAdmin = $false,
        [bool] $Reversible = $false
    )

    [pscustomobject]@{
        Check = $Check
        Status = $Status
        Title = $Title
        Detail = $Detail
        FixCommand = $FixCommand
        FixArguments = $FixArguments
        RequiresAdmin = $RequiresAdmin
        Reversible = $Reversible
        Selected = $false
    }
}

function Get-ToggleFindingStatus {
    param(
        [Parameter(Mandatory)] [bool] $ActualEnabled,
        [Parameter(Mandatory)] [bool] $ShouldBeEnabled,
        [ValidateSet('Warn', 'Bad')] [string] $Severity = 'Bad'
    )

    if ($ActualEnabled -eq $ShouldBeEnabled) {
        return 'Ok'
    }

    $Severity
}

function Get-SecurityScore {
    param(
        [object[]] $Findings = @()
    )

    $weights = @{ Ok = 1.0; Warn = 0.5; Bad = 0.0 }
    $scored = @($Findings | Where-Object { $weights.ContainsKey($_.Status) })
    if ($scored.Count -eq 0) {
        return 100
    }

    $sum = 0.0
    foreach ($finding in $scored) {
        $sum += $weights[$finding.Status]
    }

    [int][Math]::Round(100 * $sum / $scored.Count, [MidpointRounding]::AwayFromZero)
}

function Get-HygieneFindings {
    $findings = @()

    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $enabled = [bool]$defender.RealTimeProtectionEnabled
        $findings += New-SecurityFinding `
            -Check 'defender-realtime' `
            -Status (Get-ToggleFindingStatus -ActualEnabled $enabled -ShouldBeEnabled $true) `
            -Title 'Microsoft Defender real-time protection' `
            -Detail (if ($enabled) { 'Enabled' } else { 'Disabled' })
    }
    catch {
        $findings += New-SecurityFinding -Check 'defender-realtime' -Status 'Info' -Title 'Microsoft Defender real-time protection' -Detail 'Status unavailable'
    }

    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $allOn = ($profiles.Count -gt 0) -and (-not ($profiles | Where-Object { -not $_.Enabled }))
        $findings += New-SecurityFinding `
            -Check 'firewall' `
            -Status (Get-ToggleFindingStatus -ActualEnabled $allOn -ShouldBeEnabled $true) `
            -Title 'Windows Firewall (all profiles)' `
            -Detail (if ($allOn) { 'All profiles enabled' } else { 'One or more profiles disabled' }) `
            -FixCommand 'netsh' `
            -FixArguments @('advfirewall', 'set', 'allprofiles', 'state', 'on') `
            -RequiresAdmin $true `
            -Reversible $true
    }
    catch {
        $findings += New-SecurityFinding -Check 'firewall' -Status 'Info' -Title 'Windows Firewall (all profiles)' -Detail 'Status unavailable'
    }

    try {
        $smb = Get-SmbServerConfiguration -ErrorAction Stop
        $smb1 = [bool]$smb.EnableSMB1Protocol
        $findings += New-SecurityFinding `
            -Check 'smb1' `
            -Status (Get-ToggleFindingStatus -ActualEnabled $smb1 -ShouldBeEnabled $false) `
            -Title 'SMBv1 protocol' `
            -Detail (if ($smb1) { 'Enabled (legacy, insecure)' } else { 'Disabled' }) `
            -FixCommand 'powershell' `
            -FixArguments @('-NoProfile', '-Command', 'Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force') `
            -RequiresAdmin $true `
            -Reversible $true
    }
    catch {
        $findings += New-SecurityFinding -Check 'smb1' -Status 'Info' -Title 'SMBv1 protocol' -Detail 'Status unavailable'
    }

    try {
        $uac = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -ErrorAction Stop
        $uacOn = [int]$uac.EnableLUA -eq 1
        $findings += New-SecurityFinding `
            -Check 'uac' `
            -Status (Get-ToggleFindingStatus -ActualEnabled $uacOn -ShouldBeEnabled $true) `
            -Title 'User Account Control (UAC)' `
            -Detail (if ($uacOn) { 'Enabled' } else { 'Disabled' })
    }
    catch {
        $findings += New-SecurityFinding -Check 'uac' -Status 'Info' -Title 'User Account Control (UAC)' -Detail 'Status unavailable'
    }

    try {
        $bitlocker = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.VolumeType -eq 'OperatingSystem' }) | Select-Object -First 1
        if ($bitlocker) {
            $protected = $bitlocker.ProtectionStatus -eq 'On'
            $findings += New-SecurityFinding `
                -Check 'bitlocker' `
                -Status (Get-ToggleFindingStatus -ActualEnabled $protected -ShouldBeEnabled $true -Severity 'Warn') `
                -Title 'BitLocker (system drive)' `
                -Detail (if ($protected) { 'Protected' } else { 'Not protected' })
        }
    }
    catch {
        $findings += New-SecurityFinding -Check 'bitlocker' -Status 'Info' -Title 'BitLocker (system drive)' -Detail 'Status unavailable'
    }

    $findings
}

function Get-AccountFindings {
    $findings = @()

    try {
        $guest = Get-LocalUser -Name 'Guest' -ErrorAction Stop
        $guestOn = [bool]$guest.Enabled
        $findings += New-SecurityFinding `
            -Check 'guest-account' `
            -Status (Get-ToggleFindingStatus -ActualEnabled $guestOn -ShouldBeEnabled $false) `
            -Title 'Guest account' `
            -Detail (if ($guestOn) { 'Enabled' } else { 'Disabled' }) `
            -FixCommand 'net' `
            -FixArguments @('user', 'guest', '/active:no') `
            -RequiresAdmin $true `
            -Reversible $true
    }
    catch {
        $findings += New-SecurityFinding -Check 'guest-account' -Status 'Info' -Title 'Guest account' -Detail 'Status unavailable'
    }

    try {
        $neverExpires = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled -and $_.PasswordNeverExpires })
        if ($neverExpires.Count -gt 0) {
            $findings += New-SecurityFinding `
                -Check 'password-never-expires' `
                -Status 'Warn' `
                -Title 'Accounts with non-expiring passwords' `
                -Detail (($neverExpires | Select-Object -ExpandProperty Name) -join ', ')
        }
        else {
            $findings += New-SecurityFinding -Check 'password-never-expires' -Status 'Ok' -Title 'Accounts with non-expiring passwords' -Detail 'None'
        }
    }
    catch {
        $findings += New-SecurityFinding -Check 'password-never-expires' -Status 'Info' -Title 'Accounts with non-expiring passwords' -Detail 'Status unavailable'
    }

    try {
        $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
        $findings += New-SecurityFinding `
            -Check 'admin-members' `
            -Status 'Info' `
            -Title 'Administrators group members' `
            -Detail (($admins | Select-Object -ExpandProperty Name) -join ', ')
    }
    catch {
        $findings += New-SecurityFinding -Check 'admin-members' -Status 'Info' -Title 'Administrators group members' -Detail 'Status unavailable'
    }

    $findings
}

function Get-SecurityFindings {
    @(
        Get-HygieneFindings
        Get-AccountFindings
    )
}

function Get-FixableSecurityFindings {
    param(
        [object[]] $Findings = @()
    )

    @($Findings | Where-Object { $_.FixCommand })
}

function Invoke-SecurityFix {
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [switch] $DryRun
    )

    if (-not $Finding.FixCommand) {
        throw "No fix is configured for '$($Finding.Title)'."
    }

    if ($DryRun) {
        Write-Host ("DRY RUN {0} {1}" -f $Finding.FixCommand, ($Finding.FixArguments -join ' '))
        return
    }

    if ($Finding.RequiresAdmin -and -not (Test-IsAdministrator)) {
        throw "'$($Finding.Title)' fix requires an elevated terminal. Start PowerShell with Run as Administrator and try again."
    }

    Write-Host ("Applying fix: {0}..." -f $Finding.Title)
    $result = Invoke-NativeText -FilePath $Finding.FixCommand -Arguments @($Finding.FixArguments)
    if ($result.StdOut) {
        Write-Host $result.StdOut.TrimEnd()
    }
    if ($result.StdErr) {
        Write-Warning $result.StdErr.TrimEnd()
    }
    if ($result.ExitCode -ne 0) {
        throw "$($Finding.FixCommand) exited with code $($result.ExitCode) for '$($Finding.Title)'."
    }
}

function Format-SecurityFinding {
    param(
        [Parameter(Mandatory)] [object] $Item
    )

    $glyph = Get-StatusGlyph -Status $Item.Status
    $line = "$glyph $($Item.Title)"
    if ($Item.Detail) {
        $line += " - $($Item.Detail)"
    }
    $flags = @()
    if ($Item.FixCommand) { $flags += 'fixable' }
    if ($Item.Reversible) { $flags += 'reversible' }
    if ($Item.RequiresAdmin) { $flags += 'admin' }
    if ($flags.Count -gt 0) {
        $line += " ({0})" -f ($flags -join ', ')
    }

    $line
}

function Invoke-SecurityFlow {
    Clear-Host
    Write-Host 'Scanning security settings...'
    $findings = @(Get-SecurityFindings)
    Show-SecurityReport -Findings $findings

    $fixable = @(Get-FixableSecurityFindings -Findings $findings | Where-Object { $_.Status -ne 'Ok' })
    if ($fixable.Count -eq 0) {
        Write-Host ''
        Write-Host 'No fixes available for the current findings.'
        return
    }

    Write-Host ''
    $answer = Read-Host "Review $($fixable.Count) available fix(es)? Type F to choose"
    if ($answer -ne 'F') {
        return
    }

    $selected = @(Invoke-ChecklistMenu -Items $fixable -Title 'Apply fixes (Space toggles, Enter confirms)' -ItemFormatter { param($Item) Format-SecurityFinding -Item $Item })
    if ($selected.Count -eq 0) {
        Write-Host 'No fixes selected.'
        return
    }

    $elevated = Test-IsAdministrator
    $applyForReal = $false
    if ($elevated) {
        $applyForReal = (Read-Host "Apply $($selected.Count) selected fix(es) for real? Type Y (otherwise dry-run)") -eq 'Y'
    }
    else {
        Write-Host 'Not running elevated: showing a dry-run only. Re-run as Administrator to apply fixes.'
    }

    foreach ($finding in $selected) {
        try {
            Invoke-SecurityFix -Finding $finding -DryRun:(-not $applyForReal)
        }
        catch {
            Write-Warning "$($finding.Title): $($_.Exception.Message)"
        }
    }
}

function Show-SecurityReport {
    param(
        [Parameter(Mandatory)] [object[]] $Findings
    )

    $score = Get-SecurityScore -Findings $Findings
    $scoreStatus = if ($score -ge 80) { 'Ok' } elseif ($score -ge 50) { 'Warn' } else { 'Bad' }

    Write-Header -Title 'Security' -Subtitle 'Settings hygiene and account audit'
    Write-Host ''
    Write-StatusLine -Status $scoreStatus -Label 'Security score' -Value "$score / 100"
    Write-Host ''

    foreach ($finding in $Findings) {
        Write-StatusLine -Status $finding.Status -Label $finding.Title -Value $finding.Detail
    }
}
