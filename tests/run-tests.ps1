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
        -ProjectRoot 'D:\projects\My_AI\program_update_all' `
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

if ($script:Failed -gt 0) {
    throw "$script:Failed test(s) failed, $script:Passed passed."
}

Write-Host "$script:Passed test(s) passed."
