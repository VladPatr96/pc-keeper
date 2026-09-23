$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src/ProgramUpdateAll.psm1'
Import-Module $modulePath -Force

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param(
        [AllowNull()] [object] $Actual,
        [AllowNull()] [object] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected [$Expected], got [$Actual]."
    }
}

function It {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name"
        Write-Host "  $($_.Exception.Message)"
    }
}

It 'parses winget upgrade table into update candidates' {
    $text = @'
Name                 Id                         Version Available Source
---------------------------------------------------------------------------
Microsoft PowerShell Microsoft.PowerShell       7.4.1   7.5.0     winget
Claude               Anthropic.Claude           0.12.0  0.13.0    winget
'@

    $items = ConvertFrom-WingetUpgradeTable -Text $text

    Assert-Equal $items.Count 2 'winget candidate count'
    Assert-Equal $items[0].Provider 'winget' 'first provider'
    Assert-Equal $items[0].Name 'Microsoft PowerShell' 'first name'
    Assert-Equal $items[0].Id 'Microsoft.PowerShell' 'first id'
    Assert-Equal $items[0].InstalledVersion '7.4.1' 'first installed version'
    Assert-Equal $items[0].AvailableVersion '7.5.0' 'first available version'
    Assert-Equal $items[1].Name 'Claude' 'second name'
}

It 'parses winget rows when column headers are localized' {
    $text = @'
Имя                  ИД                    Версия Доступно Источник
-------------------------------------------------------------------
Claude Desktop       Anthropic.Claude      0.12.0 0.13.0   winget
'@

    $items = ConvertFrom-WingetUpgradeTable -Text $text

    Assert-Equal $items.Count 1 'localized winget candidate count'
    Assert-Equal $items[0].Name 'Claude Desktop' 'localized winget name'
    Assert-Equal $items[0].Id 'Anthropic.Claude' 'localized winget id'
}

It 'skips localized winget informational notes after the upgrade table' {
    $text = @'
Имя                  ИД                    Версия Доступно Источник
-------------------------------------------------------------------
Claude               Anthropic.Claude      0.12.0 0.13.0   winget
Несколько (1) пакетов содержат номера версий, которые невозможно определить.
'@

    $items = ConvertFrom-WingetUpgradeTable -Text $text

    Assert-Equal $items.Count 1 'winget package count excludes localized note'
    Assert-Equal $items[0].Name 'Claude' 'winget keeps real package'
}

It 'skips mojibake winget informational notes after the upgrade table' {
    $text = @'
Имя                  ИД                    Версия Доступно Источник
-------------------------------------------------------------------
Claude               Anthropic.Claude      0.12.0 0.13.0   winget
╨Э╨╡╤Б╨║╨╛╨╗╤М╨║╨╛ (1) ╨┐╨░╨║╨╡╤В╨╛╨▓ ╤Б╨╛╨┤╨╡╤А╨╢╨░╤В ╨╜╨╛╨╝╨╡╤А╨░ ╨▓╨╡╤А╤Б╨╕╨╣, ╨║╨╛╤В╨╛╤А╤Л╨╡ ╨╜╨╡╨▓╨╛╨╖╨╝╨╛╨╢╨╜╨╛ ╨╛╨┐╤А╨╡╨┤╨╡╨╗╨╕╤В╤М. ╨Ш╤Б╨┐╨╛╨╗╤М╨╖╤Г╨╣╤В╨╡ ╨┐╨░╤А╨░╨╝╨╡╤В╤А --include-unknown (╨┐╤А╨╛╤Б╨╝╨╛╤В╤А╨░ -> ╨▓╤Б╨╡╤Е)
'@

    $items = ConvertFrom-WingetUpgradeTable -Text $text

    Assert-Equal @($items).Count 1 'winget package count excludes mojibake note'
    Assert-Equal $items[0].Name 'Claude' 'winget keeps package before mojibake note'
}

It 'parses npm outdated json into update candidates' {
    $json = @'
{
  "@anthropic-ai/claude-code": {
    "current": "1.0.1",
    "wanted": "1.0.2",
    "latest": "1.0.3",
    "location": "C:\\Users\\user\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code"
  },
  "@openai/codex": {
    "current": "0.4.0",
    "wanted": "0.4.1",
    "latest": "0.5.0",
    "location": "C:\\Users\\user\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex"
  }
}
'@

    $items = ConvertFrom-NpmOutdatedJson -Json $json

    Assert-Equal $items.Count 2 'npm candidate count'
    Assert-Equal $items[0].Provider 'npm-global' 'first npm provider'
    Assert-Equal $items[0].Name '@anthropic-ai/claude-code' 'first npm name'
    Assert-Equal $items[0].InstalledVersion '1.0.1' 'first npm installed version'
    Assert-Equal $items[0].AvailableVersion '1.0.3' 'first npm available version'
    Assert-Equal $items[1].Name '@openai/codex' 'second npm name'
}

It 'parses npm global list json and tolerates entries without a version' {
    $json = @'
{
  "name": "npm-global",
  "dependencies": {
    "@anthropic-ai/claude-code": { "version": "1.0.3", "overridden": false },
    "broken-package": { "required": "^2.0.0", "missing": true }
  }
}
'@

    $items = @(ConvertFrom-NpmListJson -Json $json)

    Assert-Equal $items.Count 2 'npm list inventory count'
    Assert-Equal $items[0].Name '@anthropic-ai/claude-code' 'npm list first name'
    Assert-Equal $items[0].Version '1.0.3' 'npm list first version'
    Assert-Equal $items[0].Source 'npm-global' 'npm list source'
    Assert-Equal $items[1].Name 'broken-package' 'npm list keeps version-less entry'
    Assert-Equal $items[1].Version '' 'npm list version-less entry has empty version'
}

It 'updates checklist state for space, all, and invert commands' {
    $items = @(
        [pscustomobject]@{ Id = 'a'; Selected = $false },
        [pscustomobject]@{ Id = 'b'; Selected = $false },
        [pscustomobject]@{ Id = 'c'; Selected = $true }
    )

    Update-ChecklistState -Items $items -Action ToggleCurrent -Index 1 | Out-Null
    Assert-Equal $items[1].Selected $true 'toggle current selects current item'

    Update-ChecklistState -Items $items -Action SelectAll -Index 0 | Out-Null
    Assert-Equal @($items | Where-Object Selected).Count 3 'select all selects every item'

    Update-ChecklistState -Items $items -Action InvertAll -Index 0 | Out-Null
    Assert-Equal @($items | Where-Object Selected).Count 0 'invert all clears selected items'
}

It 'skips chocolatey rows where installed and available versions match' {
    $text = @'
git|2.44.0|2.45.0|false
ripgrep|14.1.0|14.1.0|false
'@

    $items = ConvertFrom-ChocoOutdatedText -Text $text

    Assert-Equal $items.Count 1 'chocolatey outdated candidate count'
    Assert-Equal $items[0].Name 'git' 'chocolatey keeps outdated package'
    Assert-Equal $items[0].InstalledVersion '2.44.0' 'chocolatey installed version'
    Assert-Equal $items[0].AvailableVersion '2.45.0' 'chocolatey available version'
    Assert-Equal $items[0].RequiresAdmin $true 'chocolatey updates require admin'
}

It 'returns a clear privilege error for admin-only updates in non-elevated shells' {
    $candidate = [pscustomobject]@{
        Name = 'opencode'
        Provider = 'chocolatey'
        RequiresAdmin = $true
    }

    $message = Get-UpdatePrivilegeError -Candidate $candidate -IsAdministrator:$false

    Assert-Equal ($message -match 'requires an elevated terminal') $true 'admin-only update has clear privilege error'
    Assert-Equal (Get-UpdatePrivilegeError -Candidate $candidate -IsAdministrator:$true) '' 'admin shell has no privilege error'
}

It 'collects admin-only updates before running selected updates' {
    $items = @(
        [pscustomobject]@{
            Name = 'Driver'
            Provider = 'windows-update-driver'
            RequiresAdmin = $true
        },
        [pscustomobject]@{
            Name = 'npm'
            Provider = 'npm-global'
            RequiresAdmin = $false
        }
    )

    $blocked = @(Get-PrivilegeBlockedUpdateCandidates -Candidates $items -IsAdministrator:$false)
    $blockedAsAdmin = @(Get-PrivilegeBlockedUpdateCandidates -Candidates $items -IsAdministrator:$true)

    Assert-Equal $blocked.Count 1 'one selected update requires admin'
    Assert-Equal $blocked[0].Name 'Driver' 'admin-only selected update is reported'
    Assert-Equal $blockedAsAdmin.Count 0 'admin shell has no blocked selected updates'
}

It 'captures output from native commands without using a PowerShell pipeline' {
    $result = Invoke-NativeText -FilePath 'cmd.exe' -Arguments @('/d', '/c', 'echo native-ok')

    Assert-Equal $result.ExitCode 0 'native command exit code'
    Assert-Equal $result.StdOut.Trim() 'native-ok' 'native command stdout'
}

It 'captures utf8 output from native commands without mojibake' {
    $result = Invoke-NativeText -FilePath 'pwsh' -Arguments @(
        '-NoProfile',
        '-Command',
        "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); [Console]::Out.Write('Несколько пакетов')"
    )

    Assert-Equal $result.ExitCode 0 'utf8 native command exit code'
    Assert-Equal $result.StdOut.Trim() 'Несколько пакетов' 'utf8 native command stdout'
}

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

It 'builds a command shim that forwards arguments to the project command' {
    $text = New-CommandShimText -TargetCommand 'D:\projects\My_AI\program_update_all\program-update-all.cmd'

    Assert-Equal ($text -match '@echo off') $true 'shim disables echo'
    Assert-Equal ($text -match 'call "D:\\projects\\My_AI\\program_update_all\\program-update-all.cmd" %\*') $true 'shim forwards all arguments'
    Assert-Equal ($text -match 'exit /b %ERRORLEVEL%') $true 'shim returns target exit code'
}

It 'installs update-all shim into a specified directory' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'program_update_all_tests'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $shimPath = Join-Path $dir 'update-all.cmd'
    if (Test-Path $shimPath) {
        Remove-Item -LiteralPath $shimPath -Force
    }

    $result = Install-ProgramUpdateAllCommand `
        -ProjectRoot $repoRoot `
        -ShimDirectory $dir `
        -CommandName 'update-all.cmd'

    Assert-Equal $result.ShimPath $shimPath 'installed shim path'
    Assert-Equal (Test-Path $shimPath) $true 'installed shim file exists'
    Assert-Equal ((Get-Content -Raw -Path $shimPath) -match 'program-update-all.cmd" %\*') $true 'installed shim forwards arguments'
}

It 'reports external tool diagnostic status for available and missing commands' {
    $available = Test-ExternalTool -Provider 'cmd-test' -CommandName 'cmd.exe' -VersionArguments @('/d', '/c', 'echo ok')
    $missing = Test-ExternalTool -Provider 'missing-test' -CommandName 'program-update-all-missing-command.exe'

    Assert-Equal $available.Provider 'cmd-test' 'available provider name'
    Assert-Equal $available.Installed $true 'available command installed'
    Assert-Equal $available.Starts $true 'available command starts'
    Assert-Equal $available.ExitCode 0 'available command exit code'
    Assert-Equal ($available.Message -match 'ok') $true 'available command message includes output'
    Assert-Equal $missing.Provider 'missing-test' 'missing provider name'
    Assert-Equal $missing.Installed $false 'missing command not installed'
    Assert-Equal $missing.Starts $false 'missing command does not start'
}

It 'converts uninstall registry entries into installed application inventory items' {
    $entry = [pscustomobject]@{
        DisplayName = 'Claude Desktop'
        DisplayVersion = '0.13.0'
        Publisher = 'Anthropic'
        InstallLocation = 'C:\Users\user\AppData\Local\Programs\Claude'
        SystemComponent = 0
        ReleaseType = ''
    }

    $emptyName = [pscustomobject]@{
        DisplayName = ''
        DisplayVersion = '1.0.0'
        Publisher = 'Example'
        InstallLocation = ''
        SystemComponent = 0
        ReleaseType = ''
    }

    $systemComponent = [pscustomobject]@{
        DisplayName = 'Hidden Runtime'
        DisplayVersion = '1.0.0'
        Publisher = 'Example'
        InstallLocation = ''
        SystemComponent = 1
        ReleaseType = ''
    }

    $item = ConvertFrom-UninstallRegistryEntry -Entry $entry -Source 'HKCU'

    Assert-Equal $item.Name 'Claude Desktop' 'inventory app name'
    Assert-Equal $item.Version '0.13.0' 'inventory app version'
    Assert-Equal $item.Publisher 'Anthropic' 'inventory app publisher'
    Assert-Equal $item.Source 'HKCU' 'inventory app source'
    Assert-Equal $item.UpdateProvider 'winget/manual' 'inventory app update provider hint'
    Assert-Equal (ConvertFrom-UninstallRegistryEntry -Entry $emptyName -Source 'HKCU') $null 'empty display name skipped'
    Assert-Equal (ConvertFrom-UninstallRegistryEntry -Entry $systemComponent -Source 'HKLM') $null 'system component skipped'
}

It 'parses electron app-update yml metadata' {
    $text = @'
owner: AndyMik90
repo: Auto-Claude
provider: github
updaterCacheDirName: auto-claude-ui-updater
'@

    $metadata = ConvertFrom-ElectronAppUpdateYaml -Text $text

    Assert-Equal $metadata.Owner 'AndyMik90' 'electron yml owner'
    Assert-Equal $metadata.Repo 'Auto-Claude' 'electron yml repo'
    Assert-Equal $metadata.Provider 'github' 'electron yml provider'
    Assert-Equal $metadata.UpdaterCacheDirName 'auto-claude-ui-updater' 'electron yml updater cache dir'
}

It 'creates github electron update candidate from newer release json' {
    $app = [pscustomobject]@{
        Name = 'Auto-Claude'
        CurrentVersion = '2.7.6'
        Owner = 'AndyMik90'
        Repo = 'Auto-Claude'
        AppDirectory = 'C:\Users\user\AppData\Local\Programs\auto-claude-ui'
        ExePath = 'C:\Users\user\AppData\Local\Programs\auto-claude-ui\Auto-Claude.exe'
        UpdaterCacheDirName = 'auto-claude-ui-updater'
    }
    $json = @'
[
  {
    "tag_name": "v2.8.0-beta.6",
    "draft": false,
    "prerelease": true,
    "html_url": "https://github.com/AndyMik90/Auto-Claude/releases/tag/v2.8.0-beta.6",
    "assets": [
      {
        "name": "Auto-Claude-2.8.0-beta.6-win32-x64.exe",
        "browser_download_url": "https://github.com/AndyMik90/Auto-Claude/releases/download/v2.8.0-beta.6/Auto-Claude-2.8.0-beta.6-win32-x64.exe"
      },
      {
        "name": "latest.yml",
        "browser_download_url": "https://example.invalid/latest.yml"
      }
    ]
  }
]
'@

    $candidate = ConvertFrom-GitHubElectronReleaseJson -App $app -Json $json

    Assert-Equal $candidate.Provider 'github-electron' 'github electron provider'
    Assert-Equal $candidate.Name 'Auto-Claude' 'github electron candidate name'
    Assert-Equal $candidate.InstalledVersion '2.7.6' 'github electron installed version'
    Assert-Equal $candidate.AvailableVersion '2.8.0-beta.6' 'github electron available version'
    Assert-Equal $candidate.Source 'GitHub: AndyMik90/Auto-Claude' 'github electron source'
    Assert-Equal $candidate.UpdateCommand 'github-electron' 'github electron update command'
    Assert-Equal $candidate.Metadata.InstallerFileName 'Auto-Claude-2.8.0-beta.6-win32-x64.exe' 'github electron installer asset'
}

It 'does not create github electron update candidate when release is not newer' {
    $app = [pscustomobject]@{
        Name = 'Aperant'
        CurrentVersion = '2.8.0-beta.6'
        Owner = 'AndyMik90'
        Repo = 'Aperant'
        AppDirectory = 'C:\Users\user\AppData\Local\Programs\aperant'
        ExePath = 'C:\Users\user\AppData\Local\Programs\aperant\Aperant.exe'
        UpdaterCacheDirName = 'aperant-updater'
    }
    $json = @'
[
  {
    "tag_name": "v2.8.0-beta.6",
    "draft": false,
    "prerelease": true,
    "html_url": "https://github.com/AndyMik90/Aperant/releases/tag/v2.8.0-beta.6",
    "assets": [
      {
        "name": "Aperant-2.8.0-beta.6-win32-x64.exe",
        "browser_download_url": "https://github.com/AndyMik90/Aperant/releases/download/v2.8.0-beta.6/Aperant-2.8.0-beta.6-win32-x64.exe"
      }
    ]
  }
]
'@

    $candidate = ConvertFrom-GitHubElectronReleaseJson -App $app -Json $json

    Assert-Equal $candidate $null 'same github electron version has no candidate'
}

It 'converts electron github app metadata into inventory item' {
    $app = [pscustomobject]@{
        Name = 'Aperant'
        CurrentVersion = '2.8.0-beta.6'
        Owner = 'AndyMik90'
        Repo = 'Aperant'
        AppDirectory = 'C:\Users\user\AppData\Local\Programs\aperant'
    }

    $item = ConvertTo-ElectronGitHubInventoryItem -App $app

    Assert-Equal $item.Name 'Aperant' 'electron inventory name'
    Assert-Equal $item.Version '2.8.0-beta.6' 'electron inventory version'
    Assert-Equal $item.Publisher 'GitHub: AndyMik90/Aperant' 'electron inventory publisher'
    Assert-Equal $item.Source 'github-electron' 'electron inventory source'
    Assert-Equal $item.UpdateProvider 'github-electron' 'electron inventory update provider'
}

It 'parses git ls-remote output into a commit hash' {
    $text = @'
0123456789abcdef0123456789abcdef01234567	refs/heads/main
'@

    $hash = ConvertFrom-GitLsRemoteText -Text $text

    Assert-Equal $hash '0123456789abcdef0123456789abcdef01234567' 'ls-remote commit hash'
    Assert-Equal (ConvertFrom-GitLsRemoteText -Text '') '' 'empty ls-remote output'
}

It 'converts local git app metadata into inventory item' {
    $app = [pscustomobject]@{
        Name = 'Paperclip'
        Version = '0.3.1+abcdef0'
        Publisher = 'GitHub: paperclipai/paperclip'
        RepoPath = 'D:\projects\Projects\github\paperclip\paperclip'
    }

    $item = ConvertTo-LocalGitAppInventoryItem -App $app

    Assert-Equal $item.Name 'Paperclip' 'local git inventory name'
    Assert-Equal $item.Version '0.3.1+abcdef0' 'local git inventory version'
    Assert-Equal $item.Publisher 'GitHub: paperclipai/paperclip' 'local git inventory publisher'
    Assert-Equal $item.Source 'local-git-app' 'local git inventory source'
    Assert-Equal $item.UpdateProvider 'local-git-app' 'local git update provider'
    Assert-Equal $item.InstallLocation 'D:\projects\Projects\github\paperclip\paperclip' 'local git install path'
}

It 'returns a distinct status glyph per status level' {
    Assert-Equal (Get-StatusGlyph -Status 'Ok') ([char]0x2713) 'ok glyph'
    Assert-Equal (Get-StatusGlyph -Status 'Warn') ([char]0x26A0) 'warn glyph'
    Assert-Equal (Get-StatusGlyph -Status 'Bad') ([char]0x2717) 'bad glyph'
    Assert-Equal (Get-StatusGlyph -Status 'Info') ([char]0x2022) 'info glyph'
    Assert-Equal (Get-StatusGlyph -Status 'Unknown') ([char]0x2022) 'unknown falls back to info glyph'
}

It 'formats a status line containing the glyph, label, and value' {
    $line = Format-StatusLine -Status 'Warn' -Label 'Disk C:' -Value '95% full'

    Assert-Equal ($line -match 'Disk C:') $true 'status line includes label'
    Assert-Equal ($line -match '95% full') $true 'status line includes value'
    Assert-Equal ($line.Contains([char]0x26A0)) $true 'status line includes warn glyph'
}

It 'formats a status line without a trailing separator when value is empty' {
    $line = Format-StatusLine -Status 'Ok' -Label 'Firewall' -Value ''

    Assert-Equal ($line -match 'Firewall') $true 'label rendered'
    Assert-Equal ($line -match 'Firewall:\s*$') $false 'no dangling colon for empty value'
}

It 'wraps the menu index when navigating past either end' {
    Assert-Equal (Get-NextMenuIndex -Current 0 -Delta -1 -Count 4) 3 'up from top wraps to bottom'
    Assert-Equal (Get-NextMenuIndex -Current 3 -Delta 1 -Count 4) 0 'down from bottom wraps to top'
    Assert-Equal (Get-NextMenuIndex -Current 1 -Delta 1 -Count 4) 2 'down moves to next'
    Assert-Equal (Get-NextMenuIndex -Current 0 -Delta -1 -Count 1) 0 'single item stays put'
}

It 'exposes the four PC Keeper pillars in the main menu' {
    $items = @(Get-MainMenuItems)

    Assert-Equal $items.Count 4 'main menu pillar count'
    Assert-Equal $items[0].Id 'updates' 'first pillar is updates'
    Assert-Equal $items[1].Id 'audit' 'second pillar is audit'
    Assert-Equal $items[2].Id 'cleanup' 'third pillar is cleanup'
    Assert-Equal $items[3].Id 'security' 'fourth pillar is security'
}

It 'converts byte counts into human readable sizes' {
    Assert-Equal (ConvertTo-HumanSize -Bytes 0) '0 B' 'zero bytes'
    Assert-Equal (ConvertTo-HumanSize -Bytes 512) '512 B' 'raw bytes'
    Assert-Equal (ConvertTo-HumanSize -Bytes 1024) '1 KB' 'one kilobyte'
    Assert-Equal (ConvertTo-HumanSize -Bytes 1536) '1.5 KB' 'fractional kilobytes'
    Assert-Equal (ConvertTo-HumanSize -Bytes 1073741824) '1 GB' 'one gigabyte'
    Assert-Equal (ConvertTo-HumanSize -Bytes 5368709120) '5 GB' 'five gigabytes'
}

It 'formats uptime with and without a day component' {
    $withDays = Format-Uptime -Uptime (New-TimeSpan -Days 3 -Hours 4 -Minutes 12)
    $withoutDays = Format-Uptime -Uptime (New-TimeSpan -Hours 5 -Minutes 30)

    Assert-Equal $withDays '3d 4h 12m' 'uptime includes days'
    Assert-Equal $withoutDays '5h 30m' 'uptime drops zero days'
}

It 'flags disks over ninety percent used as a warning' {
    Assert-Equal (Get-DiskUsageStatus -UsedBytes 95 -TotalBytes 100) 'Warn' 'nearly full disk warns'
    Assert-Equal (Get-DiskUsageStatus -UsedBytes 50 -TotalBytes 100) 'Ok' 'half full disk is ok'
    Assert-Equal (Get-DiskUsageStatus -UsedBytes 90 -TotalBytes 100) 'Ok' 'exactly ninety percent is ok'
    Assert-Equal (Get-DiskUsageStatus -UsedBytes 0 -TotalBytes 0) 'Info' 'unknown capacity is info'
}

It 'formats a disk line with drive, free space, and percent used' {
    $line = Format-DiskLine -Drive 'C:' -FreeBytes 5368709120 -TotalBytes 107374182400

    Assert-Equal ($line -match 'C:') $true 'disk line includes drive letter'
    Assert-Equal ($line -match '95% used') $true 'disk line includes percent used'
    Assert-Equal ($line.Contains([char]0x26A0)) $true 'nearly full disk line uses warn glyph'
}

It 'builds a normalized cleanup candidate with safe defaults' {
    $candidate = New-CleanupCandidate -Category 'Temp' -Name 'User temp' -Paths @('C:\t') -SizeBytes 2048 -RiskLevel 'Safe'

    Assert-Equal $candidate.Category 'Temp' 'cleanup candidate category'
    Assert-Equal $candidate.Name 'User temp' 'cleanup candidate name'
    Assert-Equal $candidate.SizeBytes 2048 'cleanup candidate size'
    Assert-Equal $candidate.RiskLevel 'Safe' 'cleanup candidate risk level'
    Assert-Equal $candidate.Selected $false 'cleanup candidate not preselected'
    Assert-Equal $candidate.RequiresAdmin $false 'cleanup candidate admin default'
    Assert-Equal $candidate.RequiresClosedApp $false 'cleanup candidate closed-app default'
    Assert-Equal @($candidate.Paths).Count 1 'cleanup candidate path count'
}

It 'only treats paths inside the whitelist roots as safe to delete' {
    $roots = @('C:\Users\u\AppData\Local\Temp', 'C:\Windows\Temp')

    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Users\u\AppData\Local\Temp\abc' -SafeRoots $roots) $true 'descendant of root is safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Users\u\AppData\Local\Temp' -SafeRoots $roots) $true 'the root itself is safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Windows\System32' -SafeRoots $roots) $false 'system folder is not safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Users\u\Documents' -SafeRoots $roots) $false 'documents are not safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Windows\Temp2\x' -SafeRoots $roots) $false 'sibling with shared prefix is not safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\' -SafeRoots $roots) $false 'drive root is not safe'
    Assert-Equal (Test-IsSafeCleanupPath -Path 'C:\Windows\Temp\..\System32' -SafeRoots $roots) $false 'path traversal is rejected'
}

It 'sums the size of only the selected cleanup candidates' {
    $items = @(
        New-CleanupCandidate -Category 'Temp' -Name 'a' -Paths @('x') -SizeBytes 100 -RiskLevel 'Safe'
        New-CleanupCandidate -Category 'Temp' -Name 'b' -Paths @('y') -SizeBytes 250 -RiskLevel 'Safe'
        New-CleanupCandidate -Category 'Files' -Name 'c' -Paths @('z') -SizeBytes 999 -RiskLevel 'Review'
    )
    $items[0].Selected = $true
    $items[1].Selected = $true

    Assert-Equal (Get-SelectedCleanupSize -Candidates $items) 350 'sum of selected sizes'
    Assert-Equal (Get-SelectedCleanupSize -Candidates @()) 0 'empty selection sums to zero'
}

It 'formats a cleanup candidate with category, name, and human size' {
    $candidate = New-CleanupCandidate -Category 'Browser cache' -Name 'Edge cache' -Paths @('x') -SizeBytes 1572864 -RiskLevel 'Safe'

    $line = Format-CleanupCandidate -Item $candidate

    Assert-Equal ($line -match 'Browser cache') $true 'cleanup line includes category'
    Assert-Equal ($line -match 'Edge cache') $true 'cleanup line includes name'
    Assert-Equal ($line -match '1\.5 MB') $true 'cleanup line includes human size'
}

It 'builds a security finding with sensible defaults' {
    $finding = New-SecurityFinding -Check 'smb1' -Status 'Bad' -Title 'SMBv1 enabled' -Detail 'Legacy protocol' `
        -FixCommand 'Disable-WindowsOptionalFeature' -FixArguments @('-Online', '-FeatureName', 'SMB1Protocol') -Reversible $true

    Assert-Equal $finding.Check 'smb1' 'finding check id'
    Assert-Equal $finding.Status 'Bad' 'finding status'
    Assert-Equal $finding.Title 'SMBv1 enabled' 'finding title'
    Assert-Equal $finding.FixCommand 'Disable-WindowsOptionalFeature' 'finding fix command'
    Assert-Equal @($finding.FixArguments).Count 3 'finding fix argument count'
    Assert-Equal $finding.Reversible $true 'finding reversible flag'
    Assert-Equal $finding.Selected $false 'finding not preselected'
}

It 'classifies a toggle finding against its desired state' {
    Assert-Equal (Get-ToggleFindingStatus -ActualEnabled $true -ShouldBeEnabled $true) 'Ok' 'enabled when it should be is ok'
    Assert-Equal (Get-ToggleFindingStatus -ActualEnabled $false -ShouldBeEnabled $true) 'Bad' 'disabled protection is bad'
    Assert-Equal (Get-ToggleFindingStatus -ActualEnabled $false -ShouldBeEnabled $false) 'Ok' 'disabled when it should be is ok'
    Assert-Equal (Get-ToggleFindingStatus -ActualEnabled $true -ShouldBeEnabled $false -Severity 'Warn') 'Warn' 'unwanted feature uses given severity'
}

It 'scores security findings weighting ok, warn, and bad' {
    $findings = @(
        New-SecurityFinding -Check 'a' -Status 'Ok' -Title 'a'
        New-SecurityFinding -Check 'b' -Status 'Ok' -Title 'b'
        New-SecurityFinding -Check 'c' -Status 'Ok' -Title 'c'
        New-SecurityFinding -Check 'd' -Status 'Warn' -Title 'd'
        New-SecurityFinding -Check 'e' -Status 'Bad' -Title 'e'
        New-SecurityFinding -Check 'f' -Status 'Info' -Title 'f'
    )

    Assert-Equal (Get-SecurityScore -Findings $findings) 70 'weighted score ignoring info'
    Assert-Equal (Get-SecurityScore -Findings @()) 100 'no findings is a perfect score'

    $allBad = @(
        New-SecurityFinding -Check 'x' -Status 'Bad' -Title 'x'
        New-SecurityFinding -Check 'y' -Status 'Bad' -Title 'y'
    )
    Assert-Equal (Get-SecurityScore -Findings $allBad) 0 'all bad scores zero'
}

It 'lists only fixable security findings' {
    $findings = @(
        New-SecurityFinding -Check 'a' -Status 'Bad' -Title 'a' -FixCommand 'net'
        New-SecurityFinding -Check 'b' -Status 'Info' -Title 'b'
        New-SecurityFinding -Check 'c' -Status 'Warn' -Title 'c' -FixCommand 'netsh'
    )

    $fixable = @(Get-FixableSecurityFindings -Findings $findings)

    Assert-Equal $fixable.Count 2 'only findings with a fix command are fixable'
    Assert-Equal $fixable[0].Check 'a' 'first fixable finding'
}

It 'formats a security finding with title, detail, and fix marker' {
    $finding = New-SecurityFinding -Check 'smb1' -Status 'Bad' -Title 'SMBv1 protocol' -Detail 'Enabled' -FixCommand 'powershell' -Reversible $true

    $line = Format-SecurityFinding -Item $finding

    Assert-Equal ($line -match 'SMBv1 protocol') $true 'security line includes title'
    Assert-Equal ($line -match 'Enabled') $true 'security line includes detail'
    Assert-Equal ($line -match 'reversible') $true 'security line marks reversible fixes'
}

It 'cycles spinner frames by index' {
    $first = Get-SpinnerFrame -Index 0
    $second = Get-SpinnerFrame -Index 1

    Assert-Equal ($first -ne $second) $true 'consecutive frames differ'
    Assert-Equal (Get-SpinnerFrame -Index 0) (Get-SpinnerFrame -Index 4) 'frames wrap around'
    Assert-Equal (Get-SpinnerFrame -Index 1) (Get-SpinnerFrame -Index 5) 'frames wrap consistently'
}

It 'grades overall health from a score' {
    Assert-Equal (Get-HealthGrade -Score 100) 'Ok' 'top score is ok'
    Assert-Equal (Get-HealthGrade -Score 80) 'Ok' 'eighty is ok'
    Assert-Equal (Get-HealthGrade -Score 79) 'Warn' 'just under eighty warns'
    Assert-Equal (Get-HealthGrade -Score 50) 'Warn' 'fifty warns'
    Assert-Equal (Get-HealthGrade -Score 49) 'Bad' 'below fifty is bad'
    Assert-Equal (Get-HealthGrade -Score 0) 'Bad' 'zero is bad'
}

It 'renders an audit report as exportable text' {
    $report = [pscustomobject]@{
        Hardware = [pscustomobject]@{
            OsName = 'Windows Test'
            OsVersion = '10.0'
            OsBuild = '22631'
            Uptime = (New-TimeSpan -Hours 2 -Minutes 5)
            Cpu = 'Test CPU'
            CpuCores = 8
            MemoryBytes = 17179869184
            Gpu = 'Test GPU'
            Motherboard = 'Test Board'
            BiosVersion = '1.0'
        }
        Disks = @([pscustomobject]@{ Drive = 'C:'; FreeBytes = 1073741824; TotalBytes = 2147483648; FileSystem = 'NTFS' })
        Startup = [pscustomobject]@{ StartupCommands = @(); StoppedAutoServices = @() }
        Software = @()
    }

    $text = ConvertTo-AuditReportText -Report $report

    Assert-Equal ($text -match 'PC Keeper Audit') $true 'report text has a heading'
    Assert-Equal ($text -match 'Windows Test') $true 'report text includes the OS name'
    Assert-Equal ($text -match 'C:') $true 'report text lists disks'
}

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
    $fresh = [pscustomobject]@{ Key = 'Agent/agent/codex'; Status = 'OK'; DurationSeconds = 100; Detail = '' }
    Assert-Equal (Get-HealthVerdict -Result $fresh -History @($history[0], $history[1])).Status 'OK' 'too little history'
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
    Assert-Equal ($text.IndexOf('codex') -lt $text.IndexOf('rg ')) $true 'problem listed before healthy'
    Assert-Equal ($text -match 'Cli: 1 checked') $true 'per-kind counts'
}

if ($script:Failed -gt 0) {
    throw "$script:Failed test(s) failed, $script:Passed passed."
}

Write-Host "$script:Passed test(s) passed."
