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
        [int] $TimeoutSeconds = 30
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
    if ($NativeResult.TimedOut -and $Target.Kind -eq 'Agent' -and $NativeResult.StdOut -match '\bPONG\b') {
        # e.g. grok -p prints the answer but never exits on its own.
        return New-HealthResult -Target $Target -Status 'OK' -DurationSeconds $duration -Detail "answered, but did not exit (killed after $($Target.TimeoutSeconds) s)"
    }

    if ($NativeResult.TimedOut) {
        return New-HealthResult -Target $Target -Status 'TimedOut' -DurationSeconds $duration -Detail "no answer within $($Target.TimeoutSeconds) s"
    }

    if ($Target.Kind -eq 'Agent') {
        if ($NativeResult.StdOut -match '\bPONG\b') {
            return New-HealthResult -Target $Target -Status 'OK' -DurationSeconds $duration
        }

        # Agents print warnings and hook noise first; the real cause is the first error line.
        $lines = @(($NativeResult.StdErr + "`n" + $NativeResult.StdOut) -split "\r?\n" | Where-Object { $_.Trim() })
        $errorLine = $lines | Where-Object { $_ -match 'error' -and $_ -notmatch '^\s+at ' } | Select-Object -First 1
        $detail = if ($errorLine) { $errorLine.Trim() } else { (($lines | Select-Object -Last 3) -join ' ').Trim() }
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
            $location = $item.InstallLocation.Trim('"')
            if ($location -and (Test-Path -LiteralPath $location)) {
                $files = @(Get-ChildItem -LiteralPath $location -Filter *.exe -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
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

    $texts = (@($Title) + $Lines | ForEach-Object { "<text>$([Security.SecurityElement]::Escape($_))</text>" }) -join ''
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
        $isProblem = Test-IsHealthProblem -Result $r
        $status = if ($isProblem) { if ($r.Status -in 'Warn', 'Slow') { 'Warn' } else { 'Bad' } } elseif ($r.Status -eq 'OK') { 'Ok' } else { 'Info' }
        if (-not $isProblem -and $r.Kind -eq 'Gui') { continue }
        $duration = if ($r.DurationSeconds) { "$($r.DurationSeconds)s" } else { '' }
        $value = (@($r.Status, $r.Version, $duration, $r.Detail) | Where-Object { $_ }) -join '  '
        Write-StatusLine -Status $status -Label "$($r.Kind) $($r.Name) [$($r.Source)]" -Value $value
    }

    $okGui = @($Results | Where-Object { $_.Kind -eq 'Gui' -and $_.Status -eq 'OK' }).Count
    Write-StatusLine -Status 'Ok' -Label 'GUI programs OK' -Value "$okGui"
    Write-Host "Full report: $(Join-Path (Get-HealthDataDirectory) 'latest.txt')"
}
