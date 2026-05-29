# Update.ps1 — the "Updates" pillar: provider scanners, the normalized
# update-candidate model, inventory, diagnostics, and execution dispatch.

function New-UpdateCandidate {
    param(
        [Parameter(Mandatory)] [string] $Provider,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Id,
        [string] $InstalledVersion = '',
        [string] $AvailableVersion = '',
        [string] $Source = '',
        [string] $Category = 'Application',
        [string] $UpdateCommand = '',
        [string[]] $UpdateArguments = @(),
        [bool] $RequiresAdmin = $false,
        [hashtable] $Metadata = @{}
    )

    [pscustomobject]@{
        Provider = $Provider
        Category = $Category
        Name = $Name
        Id = $Id
        InstalledVersion = $InstalledVersion
        AvailableVersion = $AvailableVersion
        Source = $Source
        Selected = $false
        RequiresAdmin = $RequiresAdmin
        UpdateCommand = $UpdateCommand
        UpdateArguments = $UpdateArguments
        Metadata = $Metadata
    }
}

function ConvertFrom-WingetUpgradeTable {
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    $rows = ConvertFrom-FixedWidthTable -Text $Text -Columns @('Name', 'Id', 'Version', 'Available', 'Source')
    if (@($rows).Count -eq 0) {
        $rows = @()
        $afterSeparator = $false
        foreach ($line in ($Text -split "\r?\n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed) {
                continue
            }
            if ($trimmed -match '^-+$') {
                $afterSeparator = $true
                continue
            }
            if (-not $afterSeparator) {
                continue
            }

            $tokens = @($trimmed -split '\s+')
            if ($tokens.Count -lt 5) {
                continue
            }

            $nameEnd = $tokens.Count - 5
            $rows += [pscustomobject]@{
                Name = ($tokens[0..$nameEnd] -join ' ')
                Id = $tokens[$tokens.Count - 4]
                Version = $tokens[$tokens.Count - 3]
                Available = $tokens[$tokens.Count - 2]
                Source = $tokens[$tokens.Count - 1]
            }
        }
    }

    foreach ($row in $rows) {
        if (-not $row.Id -or $row.Id -match '^-+$' -or $row.Name -match '^\d+\s+upgrades?\s+available') {
            continue
        }

        if ($row.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            continue
        }

        if ($row.Version -match '[\s,]' -or $row.Available -match '[\s,]') {
            continue
        }

        $arguments = @('upgrade', '--id', $row.Id, '--accept-package-agreements', '--accept-source-agreements')
        if ($row.Source) {
            $arguments += @('--source', $row.Source)
        }

        New-UpdateCandidate `
            -Provider 'winget' `
            -Category 'Application' `
            -Name $row.Name `
            -Id $row.Id `
            -InstalledVersion $row.Version `
            -AvailableVersion $row.Available `
            -Source $row.Source `
            -UpdateCommand 'winget' `
            -UpdateArguments $arguments
    }
}

function ConvertFrom-NpmOutdatedJson {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    $parsed = $Json | ConvertFrom-Json
    foreach ($property in $parsed.PSObject.Properties) {
        $package = $property.Name
        $value = $property.Value
        $latest = if ($value.PSObject.Properties.Name -contains 'latest') { $value.latest } else { $value.wanted }
        $current = if ($value.PSObject.Properties.Name -contains 'current') { $value.current } else { '' }

        New-UpdateCandidate `
            -Provider 'npm-global' `
            -Category 'Terminal CLI' `
            -Name $package `
            -Id $package `
            -InstalledVersion $current `
            -AvailableVersion $latest `
            -Source 'npm' `
            -UpdateCommand 'npm' `
            -UpdateArguments @('install', '-g', "$package@latest")
    }
}

function ConvertFrom-ChocoOutdatedText {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )

    foreach ($line in ($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -notmatch '\|') {
            continue
        }

        $parts = $trimmed -split '\|'
        if ($parts.Count -lt 3) {
            continue
        }

        if ($parts[1] -eq $parts[2]) {
            continue
        }

        New-UpdateCandidate `
            -Provider 'chocolatey' `
            -Category 'Application' `
            -Name $parts[0] `
            -Id $parts[0] `
            -InstalledVersion $parts[1] `
            -AvailableVersion $parts[2] `
            -Source 'chocolatey' `
            -UpdateCommand 'choco' `
            -UpdateArguments @('upgrade', $parts[0], '-y') `
            -RequiresAdmin $true
    }
}

function ConvertFrom-ScoopStatusTable {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )

    foreach ($line in ($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^(Name|----|Scoop is up to date)') {
            continue
        }

        if ($trimmed -match '^(?<Name>\S+)\s+(?<Installed>\S+)\s+(?<Latest>\S+)') {
            New-UpdateCandidate `
                -Provider 'scoop' `
                -Category 'Application' `
                -Name $Matches.Name `
                -Id $Matches.Name `
                -InstalledVersion $Matches.Installed `
                -AvailableVersion $Matches.Latest `
                -Source 'scoop' `
                -UpdateCommand 'scoop' `
                -UpdateArguments @('update', $Matches.Name)
        }
    }
}

function ConvertFrom-UninstallRegistryEntry {
    param(
        [Parameter(Mandatory)] [object] $Entry,
        [Parameter(Mandatory)] [string] $Source
    )

    $name = if ($Entry.PSObject.Properties.Name -contains 'DisplayName') { [string] $Entry.DisplayName } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $systemComponent = if ($Entry.PSObject.Properties.Name -contains 'SystemComponent') { $Entry.SystemComponent } else { 0 }
    if ($systemComponent -eq 1) {
        return $null
    }

    $releaseType = if ($Entry.PSObject.Properties.Name -contains 'ReleaseType') { [string] $Entry.ReleaseType } else { '' }
    if ($releaseType -match '^(Security Update|Update Rollup|Hotfix)$') {
        return $null
    }

    $version = if ($Entry.PSObject.Properties.Name -contains 'DisplayVersion') { [string] $Entry.DisplayVersion } else { '' }
    $publisher = if ($Entry.PSObject.Properties.Name -contains 'Publisher') { [string] $Entry.Publisher } else { '' }
    $installLocation = if ($Entry.PSObject.Properties.Name -contains 'InstallLocation') { [string] $Entry.InstallLocation } else { '' }

    [pscustomobject]@{
        Name = $name.Trim()
        Version = $version.Trim()
        Publisher = $publisher.Trim()
        InstallLocation = $installLocation.Trim()
        Source = $Source
        UpdateProvider = 'winget/manual'
    }
}

function Get-InstalledApplicationInventory {
    $paths = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKLM' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKLM-WOW6432' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Source = 'HKCU' }
    )

    $items = @()
    foreach ($path in $paths) {
        if (-not (Test-Path $path.Path)) {
            continue
        }

        foreach ($entry in (Get-ItemProperty -Path $path.Path -ErrorAction SilentlyContinue)) {
            $item = ConvertFrom-UninstallRegistryEntry -Entry $entry -Source $path.Source
            if ($item) {
                $items += $item
            }
        }
    }

    $items |
        Sort-Object Name, Version, Source -Unique |
        Sort-Object Name
}

function ConvertFrom-NpmListJson {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    $parsed = $Json | ConvertFrom-Json
    if (-not ($parsed.PSObject.Properties.Name -contains 'dependencies')) {
        return @()
    }

    foreach ($property in $parsed.dependencies.PSObject.Properties) {
        $value = $property.Value
        $version = if ($value -and ($value.PSObject.Properties.Name -contains 'version')) {
            [string] $value.version
        }
        else {
            ''
        }

        [pscustomobject]@{
            Name = $property.Name
            Version = $version
            Publisher = 'npm'
            InstallLocation = ''
            Source = 'npm-global'
            UpdateProvider = 'npm-global'
        }
    }
}

function Get-NpmGlobalPackageInventory {
    if (-not (Test-CommandAvailable -Name 'npm')) {
        return @()
    }

    try {
        $result = Invoke-NativeText -FilePath 'npm' -Arguments @('list', '-g', '--depth=0', '--json')
        ConvertFrom-NpmListJson -Json $result.StdOut
    }
    catch {
        Write-Warning "Could not read npm global inventory: $($_.Exception.Message)"
        @()
    }
}

function ConvertFrom-ElectronAppUpdateYaml {
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    $values = @{}
    foreach ($line in ($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^([^:#]+)\s*:\s*(.+)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            $values[$key] = $value
        }
    }

    [pscustomobject]@{
        Owner = if ($values.ContainsKey('owner')) { $values.owner } else { '' }
        Repo = if ($values.ContainsKey('repo')) { $values.repo } else { '' }
        Provider = if ($values.ContainsKey('provider')) { $values.provider } else { '' }
        UpdaterCacheDirName = if ($values.ContainsKey('updaterCacheDirName')) { $values.updaterCacheDirName } else { '' }
    }
}

function Select-GitHubWindowsInstallerAsset {
    param(
        [Parameter(Mandatory)] [object[]] $Assets
    )

    $installers = @($Assets | Where-Object {
        $_.name -match '\.exe$' -and
        $_.name -notmatch '(?i)(blockmap|uninstall|setup\.blockmap)'
    })

    if ($installers.Count -eq 0) {
        return $null
    }

    $preferred = $installers | Where-Object { $_.name -match '(?i)(win32|windows|x64|amd64)' } | Select-Object -First 1
    if ($preferred) {
        return $preferred
    }

    $installers | Select-Object -First 1
}

function ConvertFrom-GitHubElectronReleaseJson {
    param(
        [Parameter(Mandatory)] [object] $App,
        [Parameter(Mandatory)] [string] $Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $null
    }

    $releases = @($Json | ConvertFrom-Json)
    $best = $null
    $bestVersion = ''
    $bestAsset = $null

    foreach ($release in $releases) {
        if ($release.PSObject.Properties.Name -contains 'draft' -and $release.draft) {
            continue
        }

        $version = Normalize-VersionString -Version $release.tag_name
        if (-not $version) {
            continue
        }

        if (-not (Test-VersionNewer -CandidateVersion $version -CurrentVersion $App.CurrentVersion)) {
            continue
        }

        $asset = Select-GitHubWindowsInstallerAsset -Assets @($release.assets)
        if (-not $asset) {
            continue
        }

        if (-not $best -or (Test-VersionNewer -CandidateVersion $version -CurrentVersion $bestVersion)) {
            $best = $release
            $bestVersion = $version
            $bestAsset = $asset
        }
    }

    if (-not $best) {
        return $null
    }

    New-UpdateCandidate `
        -Provider 'github-electron' `
        -Category 'Application' `
        -Name $App.Name `
        -Id "$($App.Owner)/$($App.Repo)" `
        -InstalledVersion $App.CurrentVersion `
        -AvailableVersion $bestVersion `
        -Source "GitHub: $($App.Owner)/$($App.Repo)" `
        -UpdateCommand 'github-electron' `
        -UpdateArguments @($bestAsset.browser_download_url) `
        -Metadata @{
            Owner = $App.Owner
            Repo = $App.Repo
            ReleaseUrl = $best.html_url
            InstallerUrl = $bestAsset.browser_download_url
            InstallerFileName = $bestAsset.name
            AppDirectory = $App.AppDirectory
            ExePath = $App.ExePath
            UpdaterCacheDirName = $App.UpdaterCacheDirName
        }
}

function Get-ElectronGitHubAppMetadata {
    param(
        [Parameter(Mandatory)] [string] $AppDirectory
    )

    $updateYml = Join-Path $AppDirectory 'resources/app-update.yml'
    if (-not (Test-Path $updateYml)) {
        return $null
    }

    $updateInfo = ConvertFrom-ElectronAppUpdateYaml -Text (Get-Content -Raw -Path $updateYml)
    if ($updateInfo.Provider -ne 'github' -or -not $updateInfo.Owner -or -not $updateInfo.Repo) {
        return $null
    }

    $exe = Get-ChildItem -Path $AppDirectory -Filter *.exe -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(?i:uninstall|update|installer)' } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if (-not $exe) {
        return $null
    }

    $name = if ($exe.VersionInfo.ProductName) { $exe.VersionInfo.ProductName } else { [IO.Path]::GetFileNameWithoutExtension($exe.Name) }
    $version = Normalize-VersionString -Version $exe.VersionInfo.FileVersion
    if (-not $version) {
        $version = Normalize-VersionString -Version $exe.VersionInfo.ProductVersion
    }

    if (-not $version) {
        return $null
    }

    [pscustomobject]@{
        Name = $name
        CurrentVersion = $version
        Owner = $updateInfo.Owner
        Repo = $updateInfo.Repo
        Provider = $updateInfo.Provider
        UpdaterCacheDirName = $updateInfo.UpdaterCacheDirName
        AppDirectory = $AppDirectory
        ExePath = $exe.FullName
    }
}

function Get-InstalledElectronGitHubApps {
    $programsRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    if (-not (Test-Path $programsRoot)) {
        return @()
    }

    foreach ($directory in (Get-ChildItem -Path $programsRoot -Directory -ErrorAction SilentlyContinue)) {
        $metadata = Get-ElectronGitHubAppMetadata -AppDirectory $directory.FullName
        if ($metadata) {
            $metadata
        }
    }
}

function Get-GitHubReleaseJson {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    $uri = "https://api.github.com/repos/$Owner/$Repo/releases"
    $headers = @{ 'User-Agent' = 'program_update_all' }
    $result = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    $result | ConvertTo-Json -Depth 50
}

function Test-IsDuplicateUpdateCandidate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [object[]] $ExistingCandidates = @()
    )

    foreach ($existing in $ExistingCandidates) {
        if ($existing.Name -like "*$($Candidate.Name)*" -or $Candidate.Name -like "*$($existing.Name)*") {
            return $true
        }
    }

    $false
}

function Get-GitHubElectronUpdateCandidates {
    param(
        [object[]] $ExistingCandidates = @()
    )

    $candidates = @()
    foreach ($app in (Get-InstalledElectronGitHubApps)) {
        try {
            $json = Get-GitHubReleaseJson -Owner $app.Owner -Repo $app.Repo
            $candidate = ConvertFrom-GitHubElectronReleaseJson -App $app -Json $json
            if ($candidate -and -not (Test-IsDuplicateUpdateCandidate -Candidate $candidate -ExistingCandidates $ExistingCandidates)) {
                $candidates += $candidate
            }
        }
        catch {
            Write-Warning "GitHub release scan failed for $($app.Owner)/$($app.Repo): $($_.Exception.Message)"
        }
    }

    $candidates
}

function ConvertTo-ElectronGitHubInventoryItem {
    param(
        [Parameter(Mandatory)] [object] $App
    )

    [pscustomobject]@{
        Name = $App.Name
        Version = $App.CurrentVersion
        Publisher = "GitHub: $($App.Owner)/$($App.Repo)"
        InstallLocation = $App.AppDirectory
        Source = 'github-electron'
        UpdateProvider = 'github-electron'
    }
}

function Get-ElectronGitHubAppInventory {
    foreach ($app in (Get-InstalledElectronGitHubApps)) {
        ConvertTo-ElectronGitHubInventoryItem -App $app
    }
}

function Get-PaperclipRepoPath {
    $commandPath = Resolve-ExternalCommandPath -CommandName 'paperclipai'
    if ($commandPath -and (Test-Path $commandPath)) {
        $text = Get-Content -Raw -Path $commandPath -ErrorAction SilentlyContinue
        if ($text -match '(?im)^\s*set\s+"PAPERCLIP_REPO=(?<Path>.+)"\s*$') {
            $repoPath = $Matches.Path.Trim()
            if (Test-Path (Join-Path $repoPath 'package.json')) {
                return $repoPath
            }
        }
    }

    ''
}

function Get-JsonFileVersion {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path $Path)) {
        return ''
    }

    try {
        $json = Get-Content -Raw -Path $Path | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'version') {
            return [string] $json.version
        }
    }
    catch {
        return ''
    }

    ''
}

function Get-LocalGitShortHash {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [string] $Revision = 'HEAD'
    )

    try {
        $result = Invoke-NativeText -FilePath 'git' -Arguments (New-GitRepoArguments -RepoPath $RepoPath -Arguments @('rev-parse', '--short', $Revision))
        if ($result.ExitCode -eq 0) {
            return $result.StdOut.Trim()
        }
    }
    catch {
        return ''
    }

    ''
}

function Get-LocalGitBranch {
    param(
        [Parameter(Mandatory)] [string] $RepoPath
    )

    try {
        $result = Invoke-NativeText -FilePath 'git' -Arguments (New-GitRepoArguments -RepoPath $RepoPath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD'))
        if ($result.ExitCode -eq 0) {
            return $result.StdOut.Trim()
        }
    }
    catch {
        return ''
    }

    ''
}

function Test-LocalGitRepoHasChanges {
    param(
        [Parameter(Mandatory)] [string] $RepoPath
    )

    try {
        $result = Invoke-NativeText -FilePath 'git' -Arguments (New-GitRepoArguments -RepoPath $RepoPath -Arguments @('status', '--porcelain'))
        if ($result.ExitCode -ne 0) {
            return $true
        }

        return $result.StdOut.Trim().Length -gt 0
    }
    catch {
        return $true
    }
}

function ConvertFrom-GitLsRemoteText {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )

    $line = @($Text -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -eq 0) {
        return ''
    }

    $parts = $line[0].Trim() -split '\s+'
    if ($parts.Count -lt 1) {
        return ''
    }

    $parts[0]
}

function Get-LocalGitRemoteHash {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [string] $Branch = ''
    )

    if (-not (Test-CommandAvailable -Name 'git')) {
        return ''
    }

    $refs = @()
    if ($Branch -and $Branch -ne 'HEAD') {
        $refs += "refs/heads/$Branch"
    }
    $refs += 'HEAD'

    foreach ($ref in $refs) {
        try {
            $result = Invoke-NativeText -FilePath 'git' -Arguments (New-GitRepoArguments -RepoPath $RepoPath -Arguments @('ls-remote', 'origin', $ref))
            if ($result.ExitCode -ne 0) {
                continue
            }

            $hash = ConvertFrom-GitLsRemoteText -Text $result.StdOut
            if ($hash) {
                return $hash
            }
        }
        catch {
            continue
        }
    }

    ''
}

function Get-InstalledLocalGitApps {
    $paperclipPath = Get-PaperclipRepoPath
    if ($paperclipPath) {
        $version = Get-JsonFileVersion -Path (Join-Path $paperclipPath 'cli/package.json')
        $hash = Get-LocalGitShortHash -RepoPath $paperclipPath
        $displayVersion = if ($version -and $hash) { "$version+$hash" } elseif ($version) { $version } else { $hash }

        [pscustomobject]@{
            Name = 'Paperclip'
            Id = 'paperclipai/paperclip'
            RepoPath = $paperclipPath
            Version = $displayVersion
            Branch = Get-LocalGitBranch -RepoPath $paperclipPath
            PackageManager = 'pnpm'
            InstallArguments = @('--dir', $paperclipPath, 'install')
            Publisher = 'GitHub: paperclipai/paperclip'
        }
    }
}

function New-GitRepoArguments {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $safePath = $RepoPath -replace '\\', '/'
    @('-c', "safe.directory=$safePath", '-C', $RepoPath) + $Arguments
}

function ConvertTo-LocalGitAppInventoryItem {
    param(
        [Parameter(Mandatory)] [object] $App
    )

    [pscustomobject]@{
        Name = $App.Name
        Version = $App.Version
        Publisher = $App.Publisher
        InstallLocation = $App.RepoPath
        Source = 'local-git-app'
        UpdateProvider = 'local-git-app'
    }
}

function Get-LocalGitAppInventory {
    foreach ($app in (Get-InstalledLocalGitApps)) {
        ConvertTo-LocalGitAppInventoryItem -App $app
    }
}

function Get-LocalGitAppUpdateCandidates {
    $candidates = @()
    foreach ($app in (Get-InstalledLocalGitApps)) {
        if (-not $app.RepoPath -or -not (Test-Path (Join-Path $app.RepoPath '.git'))) {
            continue
        }

        if (Test-LocalGitRepoHasChanges -RepoPath $app.RepoPath) {
            Write-Warning "Skipping local Git update check for $($app.Name) because the repository has local changes: $($app.RepoPath)"
            continue
        }

        $currentHash = Get-LocalGitShortHash -RepoPath $app.RepoPath
        if (-not $currentHash) {
            continue
        }

        $remoteHash = Get-LocalGitRemoteHash -RepoPath $app.RepoPath -Branch $app.Branch
        if (-not $remoteHash) {
            continue
        }

        if ($remoteHash.StartsWith($currentHash)) {
            continue
        }

        $candidates += New-UpdateCandidate `
            -Provider 'local-git-app' `
            -Category 'Application' `
            -Name $app.Name `
            -Id $app.Id `
            -InstalledVersion $app.Version `
            -AvailableVersion $remoteHash.Substring(0, 7) `
            -Source $app.Publisher `
            -UpdateCommand 'local-git-app' `
            -UpdateArguments @($app.RepoPath) `
            -Metadata @{
                RepoPath = $app.RepoPath
                Branch = $app.Branch
                PackageManager = $app.PackageManager
                InstallArguments = $app.InstallArguments
            }
    }

    $candidates
}

function Get-ProgramInventory {
    @(
        Get-InstalledApplicationInventory
        Get-NpmGlobalPackageInventory
        Get-ElectronGitHubAppInventory
        Get-LocalGitAppInventory
    ) | Sort-Object Name, Source
}

function Test-ExternalTool {
    param(
        [Parameter(Mandatory)] [string] $Provider,
        [Parameter(Mandatory)] [string] $CommandName,
        [string[]] $VersionArguments = @('--version')
    )

    $path = Resolve-ExternalCommandPath -CommandName $CommandName
    if (-not $path) {
        return [pscustomobject]@{
            Provider = $Provider
            Command = $CommandName
            Installed = $false
            Starts = $false
            ExitCode = $null
            Path = ''
            Message = 'Command not found on PATH.'
        }
    }

    try {
        $result = Invoke-NativeText -FilePath $CommandName -Arguments $VersionArguments
        $message = (($result.StdOut + [Environment]::NewLine + $result.StdErr).Trim())
        if (-not $message) {
            $message = "Exit code $($result.ExitCode)"
        }

        [pscustomobject]@{
            Provider = $Provider
            Command = $CommandName
            Installed = $true
            Starts = $result.ExitCode -eq 0
            ExitCode = $result.ExitCode
            Path = $path
            Message = $message
        }
    }
    catch {
        [pscustomobject]@{
            Provider = $Provider
            Command = $CommandName
            Installed = $true
            Starts = $false
            ExitCode = $null
            Path = $path
            Message = $_.Exception.Message
        }
    }
}

function Test-WindowsUpdateDriverProvider {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $null = $session.CreateUpdateSearcher()
        [pscustomobject]@{
            Provider = 'windows-update-driver'
            Command = 'Microsoft.Update.Session'
            Installed = $true
            Starts = $true
            ExitCode = 0
            Path = 'COM'
            Message = 'Windows Update COM API is available.'
        }
    }
    catch {
        [pscustomobject]@{
            Provider = 'windows-update-driver'
            Command = 'Microsoft.Update.Session'
            Installed = $true
            Starts = $false
            ExitCode = $null
            Path = 'COM'
            Message = $_.Exception.Message
        }
    }
}

function Get-UpdateProviderDiagnostics {
    @(
        Test-ExternalTool -Provider 'winget' -CommandName 'winget' -VersionArguments @('--version')
        Test-ExternalTool -Provider 'npm-global' -CommandName 'npm' -VersionArguments @('--version')
        Test-ExternalTool -Provider 'chocolatey' -CommandName 'choco' -VersionArguments @('--version')
        Test-ExternalTool -Provider 'scoop' -CommandName 'scoop' -VersionArguments @('--version')
        [pscustomobject]@{
            Provider = 'github-electron'
            Command = 'GitHub Releases API'
            Installed = $true
            Starts = $true
            ExitCode = 0
            Path = (Join-Path $env:LOCALAPPDATA 'Programs')
            Message = 'Scans Electron apps with resources/app-update.yml.'
        }
        [pscustomobject]@{
            Provider = 'local-git-app'
            Command = 'git/pnpm'
            Installed = (Test-CommandAvailable -Name 'git') -and (Test-CommandAvailable -Name 'pnpm')
            Starts = (Test-CommandAvailable -Name 'git') -and (Test-CommandAvailable -Name 'pnpm')
            ExitCode = 0
            Path = (Get-PaperclipRepoPath)
            Message = 'Scans local Git-backed apps such as Paperclip.'
        }
        Test-WindowsUpdateDriverProvider
    )
}

function Get-WingetUpdateCandidates {
    if (-not (Test-CommandAvailable -Name 'winget')) {
        return @()
    }

    Write-Verbose 'Scanning winget upgrades.'
    try {
        $result = Invoke-NativeText -FilePath 'winget' -Arguments @('upgrade', '--accept-source-agreements')
    }
    catch {
        throw "winget is installed but could not start in this session. Try running from a normal Windows Terminal session, or repair/update Microsoft App Installer. Original error: $($_.Exception.Message)"
    }

    ConvertFrom-WingetUpgradeTable -Text $result.Text
}

function Get-NpmGlobalUpdateCandidates {
    if (-not (Test-CommandAvailable -Name 'npm')) {
        return @()
    }

    Write-Verbose 'Scanning global npm packages.'
    $result = Invoke-NativeText -FilePath 'npm' -Arguments @('outdated', '-g', '--json')
    ConvertFrom-NpmOutdatedJson -Json $result.StdOut
}

function Get-ChocoUpdateCandidates {
    if (-not (Test-CommandAvailable -Name 'choco')) {
        return @()
    }

    Write-Verbose 'Scanning Chocolatey packages.'
    $result = Invoke-NativeText -FilePath 'choco' -Arguments @('outdated', '-r')
    ConvertFrom-ChocoOutdatedText -Text $result.StdOut
}

function Get-ScoopUpdateCandidates {
    if (-not (Test-CommandAvailable -Name 'scoop')) {
        return @()
    }

    Write-Verbose 'Scanning Scoop packages.'
    $result = Invoke-NativeText -FilePath 'scoop' -Arguments @('status')
    ConvertFrom-ScoopStatusTable -Text $result.StdOut
}

function Get-DriverUpdateCandidates {
    Write-Verbose 'Scanning Windows Update driver updates.'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $items = @()

        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $update = $result.Updates.Item($i)
            $items += New-UpdateCandidate `
                -Provider 'windows-update-driver' `
                -Category 'Driver' `
                -Name $update.Title `
                -Id $update.Identity.UpdateID `
                -InstalledVersion '' `
                -AvailableVersion $update.LastDeploymentChangeTime.ToString('yyyy-MM-dd') `
                -Source 'Microsoft Update' `
                -UpdateCommand 'windows-update-driver' `
                -UpdateArguments @($update.Identity.UpdateID) `
                -RequiresAdmin $true `
                -Metadata @{ RevisionNumber = $update.Identity.RevisionNumber }
        }

        $items
    }
    catch {
        Write-Warning "Could not scan Windows Update drivers: $($_.Exception.Message)"
        @()
    }
}

function Get-ProgramUpdateCandidates {
    param(
        [switch] $SkipDrivers
    )

    $candidates = @()
    $providers = @(
        @{ Name = 'winget'; Scan = { Get-WingetUpdateCandidates } },
        @{ Name = 'npm-global'; Scan = { Get-NpmGlobalUpdateCandidates } },
        @{ Name = 'chocolatey'; Scan = { Get-ChocoUpdateCandidates } },
        @{ Name = 'scoop'; Scan = { Get-ScoopUpdateCandidates } }
    )

    foreach ($provider in $providers) {
        try {
            $candidates += & $provider.Scan
        }
        catch {
            Write-Warning "$($provider.Name) scan failed: $($_.Exception.Message)"
        }
    }

    $candidates += Get-GitHubElectronUpdateCandidates -ExistingCandidates $candidates
    $candidates += Get-LocalGitAppUpdateCandidates

    if (-not $SkipDrivers) {
        $candidates += Get-DriverUpdateCandidates
    }

    $candidates | Sort-Object Category, Provider, Name
}

function Invoke-DriverUpdates {
    param(
        [Parameter(Mandatory)] [string[]] $UpdateIds,
        [switch] $DryRun
    )

    if ($DryRun) {
        Write-Host "DRY RUN windows-update-driver $($UpdateIds -join ', ')"
        return
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Driver updates require an elevated terminal. Run PowerShell as Administrator and try again.'
    }

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
    $selected = New-Object -ComObject Microsoft.Update.UpdateColl

    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $update = $result.Updates.Item($i)
        if ($UpdateIds -contains $update.Identity.UpdateID) {
            if (-not $update.EulaAccepted) {
                $update.AcceptEula()
            }
            [void] $selected.Add($update)
        }
    }

    if ($selected.Count -eq 0) {
        Write-Warning 'Selected driver updates were not found during the install pass.'
        return
    }

    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $selected
    [void] $downloader.Download()

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $selected
    $installResult = $installer.Install()
    Write-Host "Driver install result code: $($installResult.ResultCode)"
}

function Invoke-GitHubElectronUpdate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [switch] $DryRun
    )

    $installerUrl = [string] $Candidate.Metadata.InstallerUrl
    $installerFileName = [string] $Candidate.Metadata.InstallerFileName
    if (-not $installerUrl -or -not $installerFileName) {
        throw "GitHub installer metadata is missing for $($Candidate.Name)."
    }

    if ($DryRun) {
        Write-Host "DRY RUN github-electron download $installerUrl"
        return
    }

    $downloadDirectory = Join-Path $env:TEMP 'program_update_all\github-electron'
    New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null
    $installerPath = Join-Path $downloadDirectory $installerFileName

    Write-Host "Downloading $($Candidate.Name) from GitHub..."
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -Headers @{ 'User-Agent' = 'program_update_all' } -ErrorAction Stop

    Write-Host "Running installer: $installerPath"
    $process = Start-Process -FilePath $installerPath -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "GitHub installer exited with code $($process.ExitCode) for $($Candidate.Name)."
    }
}

function Invoke-LocalGitAppUpdate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [switch] $DryRun
    )

    $repoPath = [string] $Candidate.Metadata.RepoPath
    if (-not $repoPath -or -not (Test-Path $repoPath)) {
        throw "Local Git app path is missing for $($Candidate.Name)."
    }

    $installArguments = @($Candidate.Metadata.InstallArguments)
    if ($installArguments.Count -eq 0) {
        $installArguments = @('--dir', $repoPath, 'install')
    }

    if ($DryRun) {
        Write-Host "DRY RUN git -C $repoPath pull --ff-only"
        Write-Host "DRY RUN pnpm $($installArguments -join ' ')"
        return
    }

    if (Test-LocalGitRepoHasChanges -RepoPath $repoPath) {
        throw "$($Candidate.Name) repository has local changes. Commit, stash, or discard them before updating: $repoPath"
    }

    Write-Host ("Updating {0} from local Git repo..." -f $Candidate.Name)
    $pull = Invoke-NativeText -FilePath 'git' -Arguments (New-GitRepoArguments -RepoPath $repoPath -Arguments @('pull', '--ff-only'))
    if ($pull.StdOut) {
        Write-Host $pull.StdOut.TrimEnd()
    }
    if ($pull.StdErr) {
        Write-Warning $pull.StdErr.TrimEnd()
    }
    if ($pull.ExitCode -ne 0) {
        throw "git pull exited with code $($pull.ExitCode) for $($Candidate.Name)."
    }

    $install = Invoke-NativeText -FilePath 'pnpm' -Arguments $installArguments
    if ($install.StdOut) {
        Write-Host $install.StdOut.TrimEnd()
    }
    if ($install.StdErr) {
        Write-Warning $install.StdErr.TrimEnd()
    }
    if ($install.ExitCode -ne 0) {
        throw "pnpm install exited with code $($install.ExitCode) for $($Candidate.Name)."
    }
}

function Get-UpdatePrivilegeError {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [bool] $IsAdministrator = (Test-IsAdministrator)
    )

    $requiresAdmin = $false
    if ($Candidate.PSObject.Properties.Name -contains 'RequiresAdmin') {
        $requiresAdmin = [bool] $Candidate.RequiresAdmin
    }

    if ($requiresAdmin -and -not $IsAdministrator) {
        return "$($Candidate.Provider) update '$($Candidate.Name)' requires an elevated terminal. Start PowerShell with Run as Administrator and run update-all again."
    }

    ''
}

function Get-PrivilegeBlockedUpdateCandidates {
    param(
        [Parameter(Mandatory)] [object[]] $Candidates,
        [bool] $IsAdministrator = (Test-IsAdministrator)
    )

    foreach ($candidate in $Candidates) {
        $privilegeError = Get-UpdatePrivilegeError -Candidate $candidate -IsAdministrator:$IsAdministrator
        if ($privilegeError) {
            $candidate
        }
    }
}

function Invoke-UpdateCandidate {
    param(
        [Parameter(Mandatory)] [object] $Candidate,
        [switch] $DryRun
    )

    if (-not $DryRun) {
        $privilegeError = Get-UpdatePrivilegeError -Candidate $Candidate
        if ($privilegeError) {
            throw $privilegeError
        }
    }

    if ($Candidate.Provider -eq 'windows-update-driver') {
        Invoke-DriverUpdates -UpdateIds @($Candidate.Id) -DryRun:$DryRun
        return
    }

    if ($Candidate.Provider -eq 'github-electron') {
        Invoke-GitHubElectronUpdate -Candidate $Candidate -DryRun:$DryRun
        return
    }

    if ($Candidate.Provider -eq 'local-git-app') {
        Invoke-LocalGitAppUpdate -Candidate $Candidate -DryRun:$DryRun
        return
    }

    if (-not $Candidate.UpdateCommand) {
        throw "No update command is configured for $($Candidate.Name)."
    }

    if ($DryRun) {
        Write-Host ("DRY RUN {0} {1}" -f $Candidate.UpdateCommand, ($Candidate.UpdateArguments -join ' '))
        return
    }

    Write-Host ("Updating {0} via {1}..." -f $Candidate.Name, $Candidate.Provider)
    $result = Invoke-NativeText -FilePath $Candidate.UpdateCommand -Arguments @($Candidate.UpdateArguments)
    if ($result.StdOut) {
        Write-Host $result.StdOut.TrimEnd()
    }
    if ($result.StdErr) {
        Write-Warning $result.StdErr.TrimEnd()
    }
    if ($result.ExitCode -ne 0) {
        throw "$($Candidate.UpdateCommand) exited with code $($result.ExitCode) for $($Candidate.Name)."
    }
}

function New-CommandShimText {
    param(
        [Parameter(Mandatory)] [string] $TargetCommand
    )

    @"
@echo off
call "$TargetCommand" %*
exit /b %ERRORLEVEL%
"@
}

function Install-ProgramUpdateAllCommand {
    param(
        [string] $ProjectRoot = (Split-Path -Parent $PSScriptRoot),
        [string] $ShimDirectory = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        [string] $CommandName = 'update-all.cmd'
    )

    $targetCommand = Join-Path $ProjectRoot 'program-update-all.cmd'
    if (-not (Test-Path $targetCommand)) {
        throw "Target command not found: $targetCommand"
    }

    New-Item -ItemType Directory -Force -Path $ShimDirectory | Out-Null
    $shimPath = Join-Path $ShimDirectory $CommandName
    $shimText = New-CommandShimText -TargetCommand $targetCommand
    Set-Content -LiteralPath $shimPath -Value $shimText -NoNewline -Encoding ASCII

    [pscustomobject]@{
        ShimPath = $shimPath
        TargetCommand = $targetCommand
        CommandName = [IO.Path]::GetFileNameWithoutExtension($CommandName)
    }
}

function Invoke-ProgramUpdateAll {
    [CmdletBinding()]
    param(
        [switch] $All,
        [switch] $DryRun,
        [switch] $Doctor,
        [switch] $Inventory,
        [switch] $List,
        [switch] $SkipDrivers,
        [switch] $Yes
    )

    if ($Doctor) {
        Get-UpdateProviderDiagnostics |
            Select-Object Provider, Installed, Starts, ExitCode, Command, Path, Message |
            Format-Table -AutoSize -Wrap
        return
    }

    if ($Inventory) {
        $inventoryItems = @(Get-ProgramInventory)
        if ($inventoryItems.Count -eq 0) {
            Write-Host 'No installed applications found in supported inventory sources.'
            return
        }

        Show-ProgramInventory -Items $inventoryItems
        return
    }

    Write-Host 'Scanning installed update providers...'
    $items = @(Get-ProgramUpdateCandidates -SkipDrivers:$SkipDrivers)

    if ($items.Count -eq 0) {
        Write-Host 'No supported updates found.'
        return
    }

    if ($List) {
        Show-UpdateList -Items $items
        return
    }

    $selected = if ($All) {
        Update-ChecklistState -Items $items -Action SelectAll -Index 0 | Out-Null
        @($items)
    }
    else {
        Invoke-ChecklistMenu -Items $items -Title 'Program Update All'
    }

    if ($selected.Count -eq 0) {
        Write-Host 'No updates selected.'
        return
    }

    if (-not $DryRun) {
        $blocked = @(Get-PrivilegeBlockedUpdateCandidates -Candidates $selected)
        if ($blocked.Count -gt 0) {
            Write-Warning "$($blocked.Count) selected update(s) require an elevated terminal and will not be run from this session."
            Show-UpdateList -Items $blocked
            $selected = @($selected | Where-Object { -not (Get-UpdatePrivilegeError -Candidate $_) })

            if ($selected.Count -eq 0) {
                Write-Host 'No runnable updates remain. Start PowerShell with Run as Administrator and run update-all again.'
                return
            }
        }
    }

    Show-UpdateList -Items $selected

    if (-not $DryRun -and -not $Yes) {
        $answer = Read-Host "Run $($selected.Count) selected update(s)? Type Y to continue"
        if ($answer -ne 'Y') {
            Write-Host 'Cancelled.'
            return
        }
    }

    $failures = @()
    foreach ($candidate in $selected) {
        try {
            Invoke-UpdateCandidate -Candidate $candidate -DryRun:$DryRun
        }
        catch {
            $failures += [pscustomobject]@{
                Name = $candidate.Name
                Provider = $candidate.Provider
                Error = $_.Exception.Message
            }
            Write-Warning "$($candidate.Name): $($_.Exception.Message)"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host 'Some updates failed:'
        $failures | Format-Table -AutoSize
        throw "$($failures.Count) update(s) failed."
    }

    Write-Host 'Done.'
}
