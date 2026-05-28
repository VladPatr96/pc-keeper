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

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/ProgramUpdateAll.psm1'
Import-Module $modulePath -Force

Invoke-ProgramUpdateAll @PSBoundParameters
