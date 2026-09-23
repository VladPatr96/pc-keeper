# Common.ps1 — cross-cutting primitives shared by every pillar.
# Native command invocation, command discovery, privilege/version helpers,
# and the generic fixed-width table parser. No UI, no pillar-specific logic.

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-ExternalCommandPath {
    param(
        [Parameter(Mandatory)] [string] $CommandName
    )

    $command = Get-Command $CommandName -All -ErrorAction SilentlyContinue |
        Where-Object CommandType -eq 'Application' |
        Select-Object -First 1

    if (-not $command) {
        $command = Get-Command $CommandName -All -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    if (-not $command) {
        return $null
    }

    if ($command.Path) {
        return $command.Path
    }

    $command.Source
}

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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Normalize-VersionString {
    param(
        [AllowNull()] [string] $Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return ''
    }

    $trimmed = $Version.Trim() -replace '^[vV]', ''
    if ($trimmed -match '(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)') {
        return $Matches[1]
    }

    if ($trimmed -match '(\d+\.\d+)') {
        return "$($Matches[1]).0"
    }

    ''
}

function ConvertTo-SemanticVersionOrNull {
    param(
        [AllowNull()] [string] $Version
    )

    $normalized = Normalize-VersionString -Version $Version
    if (-not $normalized) {
        return $null
    }

    try {
        [System.Management.Automation.SemanticVersion] $normalized
    }
    catch {
        $null
    }
}

function Test-VersionNewer {
    param(
        [Parameter(Mandatory)] [string] $CandidateVersion,
        [Parameter(Mandatory)] [string] $CurrentVersion
    )

    $candidate = ConvertTo-SemanticVersionOrNull -Version $CandidateVersion
    $current = ConvertTo-SemanticVersionOrNull -Version $CurrentVersion
    if (-not $candidate -or -not $current) {
        return $false
    }

    $candidate.CompareTo($current) -gt 0
}

function ConvertFrom-FixedWidthTable {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string[]] $Columns
    )

    $lines = $Text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 }
    if ($lines.Count -eq 0) {
        return @()
    }

    $header = $lines | Where-Object {
        $line = $_
        ($Columns | ForEach-Object { $line.IndexOf($_) -ge 0 }) -notcontains $false
    } | Select-Object -First 1

    if (-not $header) {
        return @()
    }

    $starts = foreach ($column in $Columns) {
        [pscustomobject]@{
            Name = $column
            Start = $header.IndexOf($column)
        }
    }

    $starts = $starts | Sort-Object Start
    $headerIndex = [Array]::IndexOf($lines, $header)
    $rows = @()

    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*-+\s*$') {
            continue
        }

        $row = [ordered]@{}
        for ($c = 0; $c -lt $starts.Count; $c++) {
            $start = $starts[$c].Start
            $end = if ($c -lt ($starts.Count - 1)) { $starts[$c + 1].Start } else { $line.Length }

            if ($line.Length -le $start) {
                $value = ''
            }
            else {
                $length = [Math]::Min($end, $line.Length) - $start
                $value = $line.Substring($start, $length).Trim()
            }

            $row[$starts[$c].Name] = $value
        }

        if (($row.Values | Where-Object { $_ }).Count -gt 0) {
            $rows += [pscustomobject]$row
        }
    }

    $rows
}
