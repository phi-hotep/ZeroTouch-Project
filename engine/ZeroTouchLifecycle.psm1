<#
    ZeroTouchLifecycle.psm1
    -----------------------
    The single front door for the unified app. Imports the three building-block
    modules and routes a request to the right workflow using the JML model:

        Joiner  -> Invoke-ZtOnboarding   (create user, license, groups, welcome email)
        Mover   -> Invoke-ZtMove         (re-evaluate access for a new department)
        Leaver  -> Invoke-ZtOffboarding  (lock out, reclaim, strip groups, report)

    Dependency direction is one-way:
        ZeroTouch.Common  <-  Onboarding / Offboarding  <-  ZeroTouchLifecycle (this)

    Mover is the proof that unification pays off: it's composed entirely from stage
    functions the other two modules already expose — no new Graph code.

    IMPORTANT — -WhatIf / -Confirm forwarding:
        PowerShell does NOT auto-cascade -WhatIf or -Confirm across separately defined
        functions. This router therefore forwards both explicitly to the nested
        workflows, so `Invoke-ZtLifecycle -WhatIf` truly simulates a Leaver, and
        `Invoke-ZtLifecycle -Confirm:$false` (used by run.ps1 and the watcher) truly
        suppresses interactive prompts in non-interactive hosts.

    Usage:
        Import-Module ./ZeroTouchLifecycle.psm1 -Force
        Invoke-ZtLifecycle -Request ([pscustomobject]@{ Action='Joiner'; FirstName='Ada'; LastName='Byron'; Department='Engineering'; JobTitle='Dev'; PersonalEmail='ada@x.com' })
        Invoke-ZtLifecycle -Request ([pscustomobject]@{ Action='Leaver'; Identity='ada.byron@tenant.onmicrosoft.com' }) -Confirm:$false
        Invoke-ZtLifecycle -Request ([pscustomobject]@{ Action='Mover';  Identity='ada.byron@tenant.onmicrosoft.com'; NewDepartment='Sales' })
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ZeroTouch.Common.psm1')       -Force
Import-Module (Join-Path $PSScriptRoot 'ZeroTouchOnboarding.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'ZeroTouchOffboarding.psm1')   -Force

function Invoke-ZtMove {
    <#
        Minimal Mover: when someone changes department, grant the new department's
        access. Reuses Set-ZtUserLicense and Add-ZtUserToGroups from onboarding — no
        new API code, only composition.

        By default it ADDS new access (the common, low-risk transfer case). Removing
        stale access from the OLD department is intentionally a flag (-RemoveStale),
        because revoking access is a deliberate decision, not a default.

        Honors -WhatIf / -Confirm (forwarded to nested stage functions).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$NewDepartment,
        [switch]$RemoveStale
    )
    $isWhatIf = $WhatIfPreference -eq $true
    $cfg  = Get-ZtConfig
    $user = Resolve-ZtUser -Identity $Identity
    Write-ZtLog "=== Move: $($user.UserPrincipalName) -> $NewDepartment ===" -Level INFO

    # Update the department attribute
    if ($PSCmdlet.ShouldProcess($user.UserPrincipalName, "Set department to '$NewDepartment'")) {
        Update-MgUser -UserId $user.Id -Department $NewDepartment -ErrorAction Stop
    }

    # Grant the new department's groups (+ defaults), reusing the onboarding stage
    $newGroupIds = @($cfg.defaultGroupIds)
    $deptProp = $cfg.departmentGroupMap.PSObject.Properties | Where-Object Name -EQ $NewDepartment
    if ($deptProp) { $newGroupIds += $deptProp.Value }
    $newGroupIds = $newGroupIds | Where-Object { $_ -and $_ -notmatch '^0{8}-0{4}-0{4}-0{4}-0{12}$' } | Select-Object -Unique
    if ($newGroupIds) { Add-ZtUserToGroups -UserId $user.Id -GroupIds $newGroupIds -Confirm:$false -WhatIf:$isWhatIf | Out-Null }

    # Optionally remove access tied to OTHER departments
    if ($RemoveStale) {
        $keep = @($cfg.defaultGroupIds) + @($newGroupIds)
        $allDeptGroupIds = @()
        foreach ($p in $cfg.departmentGroupMap.PSObject.Properties) { $allDeptGroupIds += $p.Value }
        $staleGroupIds = $allDeptGroupIds | Where-Object { $keep -notcontains $_ }

        # Remove-ZtUserFromGroups strips everything editable EXCEPT excluded ids, so we
        # invert: exclude every current group that is NOT a stale department group.
        $memberGroupIds = @(Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction SilentlyContinue |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
            ForEach-Object { $_.Id })
        $exclude = $memberGroupIds | Where-Object { $staleGroupIds -notcontains $_ }
        Remove-ZtUserFromGroups -UserId $user.Id -ExcludeGroupIds $exclude -Confirm:$false -WhatIf:$isWhatIf | Out-Null
    }

    Write-ZtLog "=== Move complete for $($user.UserPrincipalName) ===" -Level INFO
    return [pscustomobject]@{ UserPrincipalName = $user.UserPrincipalName; NewDepartment = $NewDepartment }
}

function Invoke-ZtLifecycle {
    <#
        Routes one normalized request object to the right workflow. The request must
        have an .Action of Joiner / Mover / Leaver plus the fields that action needs.

        -WhatIf and -Confirm are forwarded explicitly to the nested workflows (they do
        NOT cascade automatically in PowerShell). run.ps1 and Watch-Lifecycle.ps1 call
        this with -Confirm:$false for unattended execution.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Request)

    $isWhatIf = $WhatIfPreference -eq $true

    # Was -Confirm:$false explicitly passed to us? If so, forward that suppression down.
    $suppressConfirm = $PSBoundParameters.ContainsKey('Confirm') -and ($PSBoundParameters['Confirm'] -eq $false)

    Connect-ZtGraph

    $action = Get-ZtProp $Request 'Action'
    switch ($action) {
        'Joiner' {
            $hire = [pscustomobject]@{
                FirstName     = Get-ZtProp $Request 'FirstName'
                LastName      = Get-ZtProp $Request 'LastName'
                Department    = Get-ZtProp $Request 'Department'
                JobTitle      = Get-ZtProp $Request 'JobTitle'
                PersonalEmail = Get-ZtProp $Request 'PersonalEmail'
            }
            return Invoke-ZtOnboarding -Hire $hire -WhatIf:$isWhatIf
        }
        'Mover' {
            $moverParams = @{
                Identity      = Get-ZtProp $Request 'Identity'
                NewDepartment = Get-ZtProp $Request 'NewDepartment'
                WhatIf        = $isWhatIf
            }
            if ([bool](Get-ZtProp $Request 'RemoveStaleAccess' $false)) { $moverParams.RemoveStale = $true }
            if ($suppressConfirm) { $moverParams.Confirm = $false }
            return Invoke-ZtMove @moverParams
        }
        'Leaver' {
            $leaverParams = @{ Identity = (Get-ZtProp $Request 'Identity'); WhatIf = $isWhatIf }
            if ($suppressConfirm) { $leaverParams.Confirm = $false }
            return Invoke-ZtOffboarding @leaverParams
        }
        default {
            throw "Unknown lifecycle action '$action'. Expected Joiner, Mover, or Leaver."
        }
    }
}

# Re-export the workflow entry points so callers only need to import this one module.
Export-ModuleMember -Function `
    Invoke-ZtLifecycle, Invoke-ZtMove, Invoke-ZtOnboarding, Invoke-ZtOffboarding, Connect-ZtGraph, Get-ZtConfig
