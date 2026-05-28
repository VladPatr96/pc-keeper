[CmdletBinding()]
param(
    [string] $ShimDirectory,
    [string] $CommandName = 'update-all.cmd'
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/ProgramUpdateAll.psm1'
Import-Module $modulePath -Force

$arguments = @{
    ProjectRoot = $PSScriptRoot
    CommandName = $CommandName
}

if ($ShimDirectory) {
    $arguments.ShimDirectory = $ShimDirectory
}

$result = Install-ProgramUpdateAllCommand @arguments

Write-Host "Installed command: $($result.CommandName)"
Write-Host "Shim: $($result.ShimPath)"
Write-Host "Target: $($result.TargetCommand)"
