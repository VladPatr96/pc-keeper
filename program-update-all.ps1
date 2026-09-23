[CmdletBinding()]
param(
    [switch] $All,
    [switch] $DryRun,
    [switch] $Doctor,
    [switch] $Inventory,
    [switch] $List,
    [switch] $SkipDrivers,
    [switch] $Yes,
    [switch] $Health,
    [switch] $Quiet,
    [switch] $RegisterSchedule,
    [switch] $Maintain
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/ProgramUpdateAll.psm1'
Import-Module $modulePath -Force

if ($PSBoundParameters.Count -eq 0) {
    Invoke-PcKeeper
}
else {
    Invoke-ProgramUpdateAll @PSBoundParameters
}
