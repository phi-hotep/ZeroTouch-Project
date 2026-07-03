<#
    Invoke-Lifecycle.ps1
    --------------------
    One CLI entry point for all three JML actions.

    Joiner is additive (low risk) and runs immediately.
    Mover and Leaver are destructive, so they DEFAULT TO A DRY RUN (-WhatIf). Add
    -Execute to actually apply the change. The dry run now works correctly: -WhatIf
    is forwarded through the router to every nested stage, so nothing is changed.

    Joiner:
        ./Invoke-Lifecycle.ps1 -Action Joiner -FirstName Ada -LastName Byron `
            -Department Engineering -JobTitle Developer -PersonalEmail ada@example.com

    Mover (dry run, then for real):
        ./Invoke-Lifecycle.ps1 -Action Mover -Identity ada.byron@tenant.onmicrosoft.com -NewDepartment Sales
        ./Invoke-Lifecycle.ps1 -Action Mover -Identity ada.byron@tenant.onmicrosoft.com -NewDepartment Sales -Execute

    Mover, also removing old-department access in the same operation:
        ./Invoke-Lifecycle.ps1 -Action Mover -Identity ada.byron@tenant.onmicrosoft.com -NewDepartment Sales -RemoveStaleAccess -Execute

    Leaver (dry run, then for real):
        ./Invoke-Lifecycle.ps1 -Action Leaver -Identity ada.byron@tenant.onmicrosoft.com
        ./Invoke-Lifecycle.ps1 -Action Leaver -Identity ada.byron@tenant.onmicrosoft.com -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Joiner', 'Mover', 'Leaver')][string]$Action,

    # Joiner fields
    [string]$FirstName,
    [string]$LastName,
    [string]$Department,
    [string]$JobTitle,
    [string]$PersonalEmail,

    # Mover / Leaver fields
    [string]$Identity,
    [string]$NewDepartment,

    # Mover only. Default is additive-only (old-department access kept). Add this
    # switch to also strip old-department access in the same operation.
    [switch]$RemoveStaleAccess,

    # Apply destructive actions for real (Mover / Leaver). Without it, they dry-run.
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ZeroTouchLifecycle.psm1') -Force

# Basic per-action argument validation before we touch Graph.
switch ($Action) {
    'Joiner' {
        foreach ($f in 'FirstName', 'LastName', 'Department', 'PersonalEmail') {
            if (-not (Get-Variable $f -ValueOnly)) { throw "Joiner requires -$f." }
        }
    }
    'Mover' {
        if (-not $Identity)      { throw 'Mover requires -Identity (work email / UPN).' }
        if (-not $NewDepartment) { throw 'Mover requires -NewDepartment.' }
    }
    'Leaver' {
        if (-not $Identity) { throw 'Leaver requires -Identity (work email / UPN).' }
    }
}

$request = [pscustomobject]@{
    Action            = $Action
    FirstName         = $FirstName
    LastName          = $LastName
    Department        = $Department
    JobTitle          = $JobTitle
    PersonalEmail     = $PersonalEmail
    Identity          = $Identity
    NewDepartment     = $NewDepartment
    RemoveStaleAccess = $RemoveStaleAccess.IsPresent
}

# Joiner is additive -> just run it.
if ($Action -eq 'Joiner') {
    return Invoke-ZtLifecycle -Request $request -Confirm:$false
}

# Mover / Leaver are destructive -> dry run unless -Execute.
if (-not $Execute) {
    Write-Host "DRY RUN ($Action) — no changes will be made. Re-run with -Execute to apply." -ForegroundColor Cyan
    return Invoke-ZtLifecycle -Request $request -WhatIf
}

Write-Host "EXECUTING ($Action) — applying changes." -ForegroundColor Yellow
return Invoke-ZtLifecycle -Request $request -Confirm:$false
