# Audit.ps1 — the "PC Audit" pillar. Read-only system report built from CIM
# classes (no text parsing -> no mojibake). Pure formatters carry the logic
# and are unit-tested; the Get-*Info scanners are thin CIM wrappers.

function ConvertTo-HumanSize {
    param(
        [Parameter(Mandatory)] [double] $Bytes
    )

    if ($Bytes -lt 1024) {
        return "$([long]$Bytes) B"
    }

    $units = @('KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $unitIndex = -1
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex++
    }

    $rounded = [Math]::Round($value, 1)
    $text = if ($rounded -eq [Math]::Floor($rounded)) {
        [string][long]$rounded
    }
    else {
        $rounded.ToString([Globalization.CultureInfo]::InvariantCulture)
    }

    "$text $($units[$unitIndex])"
}

function Format-Uptime {
    param(
        [Parameter(Mandatory)] [timespan] $Uptime
    )

    $days = [int]$Uptime.Days
    if ($days -gt 0) {
        return "{0}d {1}h {2}m" -f $days, $Uptime.Hours, $Uptime.Minutes
    }

    "{0}h {1}m" -f $Uptime.Hours, $Uptime.Minutes
}

function Get-DiskUsageStatus {
    param(
        [Parameter(Mandatory)] [double] $UsedBytes,
        [Parameter(Mandatory)] [double] $TotalBytes
    )

    if ($TotalBytes -le 0) {
        return 'Info'
    }

    $percentUsed = ($UsedBytes / $TotalBytes) * 100
    if ($percentUsed -gt 90) {
        return 'Warn'
    }

    'Ok'
}

function Format-DiskLine {
    param(
        [Parameter(Mandatory)] [string] $Drive,
        [Parameter(Mandatory)] [double] $FreeBytes,
        [Parameter(Mandatory)] [double] $TotalBytes
    )

    $usedBytes = $TotalBytes - $FreeBytes
    $status = Get-DiskUsageStatus -UsedBytes $usedBytes -TotalBytes $TotalBytes
    $percentUsed = if ($TotalBytes -gt 0) { [int][Math]::Round(($usedBytes / $TotalBytes) * 100) } else { 0 }

    $value = "{0} free of {1} ({2}% used)" -f `
        (ConvertTo-HumanSize -Bytes $FreeBytes), `
        (ConvertTo-HumanSize -Bytes $TotalBytes), `
        $percentUsed

    Format-StatusLine -Status $status -Label "Drive $Drive" -Value $value
}

function Get-HardwareInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue) | Select-Object -First 1
        $memory = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue) | Select-Object -First 1
        $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue

        $totalMemory = ($memory | Measure-Object -Property Capacity -Sum).Sum
        $uptime = (Get-Date) - $os.LastBootUpTime

        [pscustomobject]@{
            OsName = $os.Caption
            OsVersion = $os.Version
            OsBuild = $os.BuildNumber
            Uptime = $uptime
            Cpu = if ($cpu) { $cpu.Name } else { '' }
            CpuCores = if ($cpu) { $cpu.NumberOfCores } else { 0 }
            MemoryBytes = if ($totalMemory) { [double]$totalMemory } else { 0 }
            Gpu = if ($video) { $video.Name } else { '' }
            Motherboard = if ($board) { "$($board.Manufacturer) $($board.Product)" } else { '' }
            BiosVersion = if ($bios) { $bios.SMBIOSBIOSVersion } else { '' }
        }
    }
    catch {
        Write-Warning "Could not read hardware info: $($_.Exception.Message)"
        $null
    }
}

function Get-DiskInfo {
    $healthByNumber = @{}
    foreach ($physical in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $healthByNumber[[string]$physical.DeviceId] = $physical.HealthStatus
    }

    foreach ($disk in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{
            Drive = $disk.DeviceID
            FreeBytes = [double]$disk.FreeSpace
            TotalBytes = [double]$disk.Size
            FileSystem = $disk.FileSystem
        }
    }
}

function Get-StartupInfo {
    $startup = foreach ($entry in @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{
            Name = $entry.Name
            Command = $entry.Command
            Location = $entry.Location
            User = $entry.User
        }
    }

    $autoServices = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
        Select-Object -Property Name, DisplayName, Status, StartType)

    [pscustomobject]@{
        StartupCommands = @($startup)
        StoppedAutoServices = $autoServices
    }
}

function Get-AuditReport {
    [pscustomobject]@{
        Hardware = Get-HardwareInfo
        Disks = @(Get-DiskInfo)
        Startup = Get-StartupInfo
        Software = @(Get-ProgramInventory)
    }
}

function ConvertTo-AuditReportText {
    param(
        [Parameter(Mandatory)] [object] $Report
    )

    $lines = @()
    $lines += 'PC Keeper Audit'
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''

    $hardware = $Report.Hardware
    if ($hardware) {
        $lines += '[Hardware & OS]'
        $lines += "OS:        $($hardware.OsName) (build $($hardware.OsBuild), version $($hardware.OsVersion))"
        $lines += "Uptime:    $(Format-Uptime -Uptime $hardware.Uptime)"
        $lines += "CPU:       $($hardware.Cpu) ($($hardware.CpuCores) cores)"
        $lines += "Memory:    $(ConvertTo-HumanSize -Bytes $hardware.MemoryBytes)"
        $lines += "GPU:       $($hardware.Gpu)"
        $lines += "Board:     $($hardware.Motherboard) / BIOS $($hardware.BiosVersion)"
        $lines += ''
    }

    $lines += '[Disks]'
    foreach ($disk in @($Report.Disks)) {
        $used = $disk.TotalBytes - $disk.FreeBytes
        $percent = if ($disk.TotalBytes -gt 0) { [int][Math]::Round(($used / $disk.TotalBytes) * 100) } else { 0 }
        $lines += "{0}  {1} free of {2} ({3}% used) [{4}]" -f `
            $disk.Drive, `
            (ConvertTo-HumanSize -Bytes $disk.FreeBytes), `
            (ConvertTo-HumanSize -Bytes $disk.TotalBytes), `
            $percent, `
            $disk.FileSystem
    }
    $lines += ''

    $lines += '[Startup & services]'
    $lines += "Startup entries:       $(@($Report.Startup.StartupCommands).Count)"
    $lines += "Stopped auto services: $(@($Report.Startup.StoppedAutoServices).Count)"
    $lines += ''

    $lines += "[Installed software] $(@($Report.Software).Count) programs"

    $lines -join [Environment]::NewLine
}

function Export-AuditReport {
    param(
        [Parameter(Mandatory)] [object] $Report,
        [string] $Directory = (Join-Path $env:TEMP 'pc-keeper')
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory ("audit-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $text = ConvertTo-AuditReportText -Report $Report
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8

    $path
}

function Show-AuditReport {
    param(
        [Parameter(Mandatory)] [object] $Report
    )

    Write-Header -Title 'PC Audit' -Subtitle 'Read-only system report'
    Write-Host ''

    $hardware = $Report.Hardware
    if ($hardware) {
        Write-Host 'Hardware & OS'
        Write-StatusLine -Status 'Info' -Label 'OS' -Value "$($hardware.OsName) (build $($hardware.OsBuild))"
        Write-StatusLine -Status 'Info' -Label 'Uptime' -Value (Format-Uptime -Uptime $hardware.Uptime)
        Write-StatusLine -Status 'Info' -Label 'CPU' -Value "$($hardware.Cpu) ($($hardware.CpuCores) cores)"
        Write-StatusLine -Status 'Info' -Label 'Memory' -Value (ConvertTo-HumanSize -Bytes $hardware.MemoryBytes)
        Write-StatusLine -Status 'Info' -Label 'GPU' -Value $hardware.Gpu
        Write-StatusLine -Status 'Info' -Label 'Board' -Value "$($hardware.Motherboard) / BIOS $($hardware.BiosVersion)"
        Write-Host ''
    }

    Write-Host 'Disks'
    foreach ($disk in $Report.Disks) {
        Write-Host (Format-DiskLine -Drive $disk.Drive -FreeBytes $disk.FreeBytes -TotalBytes $disk.TotalBytes)
    }
    Write-Host ''

    Write-Host 'Startup & services'
    Write-StatusLine -Status 'Info' -Label 'Startup entries' -Value ([string]@($Report.Startup.StartupCommands).Count)
    Write-StatusLine -Status 'Info' -Label 'Stopped auto services' -Value ([string]@($Report.Startup.StoppedAutoServices).Count)
    Write-Host ''

    Write-StatusLine -Status 'Info' -Label 'Installed programs' -Value ([string]@($Report.Software).Count)
}
