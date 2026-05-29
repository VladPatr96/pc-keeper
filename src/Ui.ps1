# Ui.ps1 — rendering and interactive menus. UI never fetches data;
# scanners return objects and these functions only draw them.
# ReadKey/Clear-Host live here and are never exercised by tests.

$script:Esc = [char]27

function Get-StatusGlyph {
    param(
        [Parameter(Mandatory)] [string] $Status
    )

    switch ($Status) {
        'Ok' { [char]0x2713 }
        'Warn' { [char]0x26A0 }
        'Bad' { [char]0x2717 }
        default { [char]0x2022 }
    }
}

function Get-StatusColorCode {
    param(
        [Parameter(Mandatory)] [string] $Status
    )

    switch ($Status) {
        'Ok' { 32 }
        'Warn' { 33 }
        'Bad' { 31 }
        default { 90 }
    }
}

function Format-StatusLine {
    param(
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [string] $Label,
        [string] $Value = ''
    )

    $glyph = Get-StatusGlyph -Status $Status
    $color = Get-StatusColorCode -Status $Status
    $coloredGlyph = "$script:Esc[${color}m$glyph$script:Esc[0m"

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "$coloredGlyph $Label"
    }

    "$coloredGlyph ${Label}: $Value"
}

function Write-StatusLine {
    param(
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [string] $Label,
        [string] $Value = ''
    )

    Write-Host (Format-StatusLine -Status $Status -Label $Label -Value $Value)
}

function Write-Header {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $Subtitle = ''
    )

    $width = [Math]::Max($Title.Length, $Subtitle.Length) + 4
    $top = [char]0x250C + ([string][char]0x2500 * ($width - 2)) + [char]0x2510
    $bottom = [char]0x2514 + ([string][char]0x2500 * ($width - 2)) + [char]0x2518
    $side = [char]0x2502

    Write-Host "$script:Esc[36m$top$script:Esc[0m"
    Write-Host ("$script:Esc[36m$side$script:Esc[0m {0,-$($width - 4)} $script:Esc[36m$side$script:Esc[0m" -f $Title)
    if ($Subtitle) {
        Write-Host ("$script:Esc[36m$side$script:Esc[0m {0,-$($width - 4)} $script:Esc[36m$side$script:Esc[0m" -f $Subtitle)
    }
    Write-Host "$script:Esc[36m$bottom$script:Esc[0m"
}

function Get-NextMenuIndex {
    param(
        [Parameter(Mandatory)] [int] $Current,
        [Parameter(Mandatory)] [int] $Delta,
        [Parameter(Mandatory)] [int] $Count
    )

    if ($Count -le 0) {
        return 0
    }

    (($Current + $Delta) % $Count + $Count) % $Count
}

function Get-SpinnerFrame {
    param(
        [Parameter(Mandatory)] [int] $Index
    )

    $frames = @('|', '/', '-', '\')
    $frames[(($Index % $frames.Count) + $frames.Count) % $frames.Count]
}

function Get-HealthGrade {
    param(
        [Parameter(Mandatory)] [int] $Score
    )

    if ($Score -ge 80) {
        return 'Ok'
    }
    if ($Score -ge 50) {
        return 'Warn'
    }

    'Bad'
}

function Get-WorstStatus {
    param(
        [string[]] $Statuses = @()
    )

    $rank = @{ Ok = 0; Info = 0; Warn = 1; Bad = 2 }
    $worst = 'Ok'
    $worstRank = 0
    foreach ($status in $Statuses) {
        $current = if ($rank.ContainsKey($status)) { $rank[$status] } else { 0 }
        if ($current -gt $worstRank) {
            $worstRank = $current
            $worst = $status
        }
    }

    $worst
}

function Show-Spinner {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )

    $modulePath = Join-Path $PSScriptRoot 'ProgramUpdateAll.psm1'
    $powershell = [PowerShell]::Create()
    [void] $powershell.AddScript("Import-Module '$modulePath' -Force")
    [void] $powershell.AddStatement().AddScript($ScriptBlock.ToString())
    $handle = $powershell.BeginInvoke()

    $i = 0
    while (-not $handle.IsCompleted) {
        Write-Host ("`r{0} {1}" -f (Get-SpinnerFrame -Index $i), $Message) -NoNewline
        Start-Sleep -Milliseconds 100
        $i++
    }

    Write-Host ("`r{0}`r" -f (' ' * ($Message.Length + 2))) -NoNewline
    $result = $powershell.EndInvoke($handle)
    $powershell.Dispose()
    $result
}

function Get-SystemHealthSummary {
    $disks = @(Get-DiskInfo)
    $diskStatus = 'Ok'
    foreach ($disk in $disks) {
        $status = Get-DiskUsageStatus -UsedBytes ($disk.TotalBytes - $disk.FreeBytes) -TotalBytes $disk.TotalBytes
        if ($status -eq 'Warn') {
            $diskStatus = 'Warn'
        }
    }

    $findings = @(Get-SecurityFindings)
    $securityScore = Get-SecurityScore -Findings $findings
    $securityStatus = Get-HealthGrade -Score $securityScore

    [pscustomobject]@{
        DiskStatus = $diskStatus
        SecurityScore = $securityScore
        SecurityStatus = $securityStatus
        OverallStatus = Get-WorstStatus -Statuses @($diskStatus, $securityStatus)
    }
}

function Get-MainMenuItems {
    @(
        [pscustomobject]@{ Id = 'updates'; Title = 'Updates'; Subtitle = 'Update installed programs and drivers' }
        [pscustomobject]@{ Id = 'audit'; Title = 'PC Audit'; Subtitle = 'Read-only system health report' }
        [pscustomobject]@{ Id = 'cleanup'; Title = 'Cleanup'; Subtitle = 'Find and remove junk to free space' }
        [pscustomobject]@{ Id = 'security'; Title = 'Security'; Subtitle = 'Settings hygiene and account audit' }
    )
}

function Show-Banner {
    param(
        [object] $Health = $null
    )

    Write-Header -Title 'PC Keeper' -Subtitle 'Windows maintenance toolkit'

    if ($Health) {
        Write-StatusLine -Status $Health.OverallStatus -Label 'System health' -Value "disks $($Health.DiskStatus), security $($Health.SecurityScore)/100"
    }
}

function Invoke-MainMenu {
    $items = @(Get-MainMenuItems)
    $index = 0
    $health = $null

    while ($true) {
        Clear-Host
        Show-Banner -Health $health
        Write-Host ''
        Write-Host "$script:Esc[90mUp/Down: navigate  Enter: open  R: refresh health  Q/Esc: quit$script:Esc[0m"
        Write-Host ''

        for ($i = 0; $i -lt $items.Count; $i++) {
            $cursor = if ($i -eq $index) { '>' } else { ' ' }
            $title = $items[$i].Title
            $subtitle = $items[$i].Subtitle
            if ($i -eq $index) {
                Write-Host "$script:Esc[36m$cursor $title$script:Esc[0m  $script:Esc[90m$subtitle$script:Esc[0m"
            }
            else {
                Write-Host "$cursor $title  $script:Esc[90m$subtitle$script:Esc[0m"
            }
        }

        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            13 { return $items[$index].Id }
            27 { return '' }
            38 { $index = Get-NextMenuIndex -Current $index -Delta -1 -Count $items.Count }
            40 { $index = Get-NextMenuIndex -Current $index -Delta 1 -Count $items.Count }
            default {
                switch ($key.Character.ToString().ToLowerInvariant()) {
                    'q' { return '' }
                    'r' { $health = Show-Spinner -Message 'Computing system health...' -ScriptBlock { Get-SystemHealthSummary } | Select-Object -First 1 }
                }
            }
        }
    }
}

function Invoke-PcKeeper {
    while ($true) {
        $choice = Invoke-MainMenu
        switch ($choice) {
            'updates' {
                Invoke-ProgramUpdateAll
            }
            'audit' {
                Clear-Host
                $report = Show-Spinner -Message 'Collecting system audit...' -ScriptBlock { Get-AuditReport } | Select-Object -First 1
                Show-AuditReport -Report $report
                Write-Host ''
                if ((Read-Host 'Save this report to a file? Type S to save') -eq 'S') {
                    $path = Export-AuditReport -Report $report
                    Write-Host "Saved to $path"
                }
            }
            'cleanup' {
                Invoke-CleanupFlow
            }
            'security' {
                Invoke-SecurityFlow
            }
            default {
                return
            }
        }

        Write-Host ''
        Write-Host "$script:Esc[90mPress any key to return to the menu...$script:Esc[0m"
        [void] $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

function Update-ChecklistState {
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [ValidateSet('ToggleCurrent', 'SelectAll', 'ClearAll', 'InvertAll')] [string] $Action,
        [Parameter(Mandatory)] [int] $Index
    )

    switch ($Action) {
        'ToggleCurrent' {
            if ($Index -ge 0 -and $Index -lt $Items.Count) {
                $Items[$Index].Selected = -not [bool]$Items[$Index].Selected
            }
        }
        'SelectAll' {
            foreach ($item in $Items) {
                $item.Selected = $true
            }
        }
        'ClearAll' {
            foreach ($item in $Items) {
                $item.Selected = $false
            }
        }
        'InvertAll' {
            foreach ($item in $Items) {
                $item.Selected = -not [bool]$item.Selected
            }
        }
    }

    $Items
}

function Format-UpdateCandidate {
    param(
        [Parameter(Mandatory)] [object] $Item
    )

    $versionText = if ($Item.InstalledVersion -and $Item.AvailableVersion) {
        "$($Item.InstalledVersion) -> $($Item.AvailableVersion)"
    }
    elseif ($Item.AvailableVersion) {
        "available $($Item.AvailableVersion)"
    }
    else {
        'available'
    }

    "[$($Item.Provider)] $($Item.Name) ($versionText)"
}

function Invoke-ChecklistMenu {
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [string] $Title = 'Select updates',
        [scriptblock] $ItemFormatter = { param($Item) Format-UpdateCandidate -Item $Item }
    )

    if ($Items.Count -eq 0) {
        return @()
    }

    $index = 0
    while ($true) {
        Clear-Host
        Write-Host $Title
        Write-Host 'Space: toggle  A: select all  I: invert  C: clear  Enter: run selected  Q/Esc: cancel'
        Write-Host ''

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $cursor = if ($i -eq $index) { '>' } else { ' ' }
            $box = if ($Items[$i].Selected) { '[x]' } else { '[ ]' }
            Write-Host ("{0} {1} {2}" -f $cursor, $box, (& $ItemFormatter $Items[$i]))
        }

        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            13 { return @($Items | Where-Object Selected) }
            27 { return @() }
            32 { Update-ChecklistState -Items $Items -Action ToggleCurrent -Index $index | Out-Null }
            38 { if ($index -gt 0) { $index-- } }
            40 { if ($index -lt ($Items.Count - 1)) { $index++ } }
            default {
                switch ($key.Character.ToString().ToLowerInvariant()) {
                    'a' { Update-ChecklistState -Items $Items -Action SelectAll -Index $index | Out-Null }
                    'c' { Update-ChecklistState -Items $Items -Action ClearAll -Index $index | Out-Null }
                    'i' { Update-ChecklistState -Items $Items -Action InvertAll -Index $index | Out-Null }
                    'q' { return @() }
                }
            }
        }
    }
}

function Show-UpdateList {
    param(
        [Parameter(Mandatory)] [object[]] $Items
    )

    $Items |
        Select-Object Provider, Category, Name, InstalledVersion, AvailableVersion, Source |
        Format-Table -AutoSize
}

function Show-ProgramInventory {
    param(
        [Parameter(Mandatory)] [object[]] $Items
    )

    $Items |
        Select-Object Name, Version, Publisher, Source, UpdateProvider, InstallLocation |
        Format-Table -AutoSize -Wrap
}
