<#
    ZeroTouchOffboarding.psm1
    -------------------------
    Leaver pipeline — the deprovisioning counterpart to onboarding. Offboarding is
    DESTRUCTIVE, so this module is built around three rules onboarding didn't need:

      1. Lock out FIRST.  Disable + revoke sessions before anything else, so the
         account is dead the instant the run starts — even if a later stage fails.
      2. Snapshot BEFORE you strip.  Every run writes a "tombstone" JSON capturing
         the user's pre-state (enabled, licenses, group memberships, manager) so the
         action is auditable and reversible.
      3. Never hard-delete.  This module disables and strips access but RETAINS the
         object. Deletion is a separate, manually gated step after a retention period
         (see docs/OFFBOARDING.md). Disabling is reversible; deletion is not.

    Safety: every changing function supports -WhatIf and -Confirm (ConfirmImpact High).
    Run interactively to get prompts; pass -Confirm:$false for unattended runs.

    Shared helpers (Get-ZtConfig, Get-ZtSecret, Connect-ZtGraph, Write-ZtLog,
    New-ZtPassword, Get-ZtWritableDir) come from ZeroTouch.Common. Offboarding does
    NOT depend on onboarding.

    Graph application permissions (SAME app registration as onboarding):
        User.ReadWrite.All        disable, reset password, reclaim licenses, revoke sessions
        Group.ReadWrite.All       read membership + remove from groups
        Organization.Read.All     map SkuId -> SkuPartNumber for the report
    If Get-MgUserMemberOf is denied, also grant Directory.Read.All.

    Azure note: tombstones are written via Get-ZtWritableDir (ZT_LOG_DIR-aware),
    NOT under $PSScriptRoot, because the deployed filesystem is read-only. For durable
    retention in production, point ZT_LOG_DIR at a mounted Azure File share or push
    the tombstone to Blob Storage (see docs/OFFBOARDING.md).
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ZeroTouch.Common.psm1') -Force

#region helpers ---------------------------------------------------------------

function Resolve-ZtUser {
    <# Finds a user by object id, UPN, or mail. Throws if not found. #>
    param([Parameter(Mandatory)][string]$Identity)

    $props = 'Id', 'UserPrincipalName', 'DisplayName', 'AccountEnabled', 'Mail'
    $user  = $null
    try { $user = Get-MgUser -UserId $Identity -Property $props -ErrorAction Stop } catch { }
    if (-not $user) {
        $user = Get-MgUser -Filter "mail eq '$Identity' or userPrincipalName eq '$Identity'" `
                           -Property $props -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $user) { throw "User '$Identity' not found in the directory." }
    return $user
}

function Get-ZtUserSnapshot {
    <# Captures pre-state for the tombstone: enabled flag, licenses, groups, manager. #>
    param([Parameter(Mandatory)][string]$UserId)

    $licenses = @(Get-MgUserLicenseDetail -UserId $UserId -ErrorAction SilentlyContinue |
                  ForEach-Object { [pscustomobject]@{ SkuId = $_.SkuId; SkuPartNumber = $_.SkuPartNumber } })

    $groups = @(Get-MgUserMemberOf -UserId $UserId -All -ErrorAction SilentlyContinue |
                Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
                ForEach-Object { [pscustomobject]@{ Id = $_.Id; DisplayName = $_.AdditionalProperties['displayName'] } })

    $managerId = $null
    try { $managerId = (Get-MgUserManager -UserId $UserId -ErrorAction Stop).Id } catch { }

    return [pscustomobject]@{
        UserId     = $UserId
        CapturedAt = (Get-Date).ToString('o')
        Licenses   = $licenses
        Groups     = $groups
        ManagerId  = $managerId
    }
}

function Save-ZtTombstone {
    <#
        Persists the snapshot + action results to <writable>/tombstones/<upn>-<ts>.json.
        Uses Get-ZtWritableDir so it works on Azure's read-only filesystem. If NO
        writable location exists, logs a warning and returns $null rather than throwing
        — the offboarding actions themselves already succeeded and must not be undone
        by a logging failure. The full record is also emitted to the console (App
        Insights) so the audit trail survives even without file persistence.
    #>
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][pscustomobject]$Record
    )

    $json = $Record | ConvertTo-Json -Depth 8
    $dir  = Get-ZtWritableDir -SubDir 'tombstones'
    if (-not $dir) {
        Write-ZtLog "No writable location for tombstone. Emitting to console only (captured by App Insights)." -Level WARN
        Write-ZtLog "TOMBSTONE $Upn : $json" -Level INFO
        return $null
    }

    $safe = $Upn -replace '[^A-Za-z0-9.@_-]', '_'
    $file = Join-Path $dir ("{0}-{1}.json" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        Set-Content -Path $file -Value $json -ErrorAction Stop
        Write-ZtLog "Tombstone written: $file" -Level INFO
        return $file
    }
    catch {
        Write-ZtLog "Tombstone file write failed ($($_.Exception.Message)). Emitting to console instead." -Level WARN
        Write-ZtLog "TOMBSTONE $Upn : $json" -Level INFO
        return $null
    }
}

#endregion

#region stage 1: lock out (disable + revoke) ---------------------------------

function Disable-ZtUser {
    <# Blocks sign-in. Idempotent: already-disabled -> no change. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UserId)

    $u = Get-MgUser -UserId $UserId -Property Id, UserPrincipalName, AccountEnabled -ErrorAction Stop
    if (-not $u.AccountEnabled) {
        Write-ZtLog "User $($u.UserPrincipalName) already disabled. Skipping." -Level WARN
        return [pscustomobject]@{ Action = 'Disable'; Changed = $false; Reason = 'Already disabled' }
    }
    if ($PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Disable account (block sign-in)')) {
        Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop
        Write-ZtLog "Disabled $($u.UserPrincipalName)." -Level INFO
        return [pscustomobject]@{ Action = 'Disable'; Changed = $true; Reason = 'Disabled' }
    }
    return [pscustomobject]@{ Action = 'Disable'; Changed = $false; Reason = 'WhatIf' }
}

function Revoke-ZtUserSessions {
    <#
        Invalidates all refresh tokens so existing sessions die. Disabling alone does
        NOT immediately kill active tokens — this is what makes the lockout real.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UserId)

    if ($PSCmdlet.ShouldProcess($UserId, 'Revoke all sign-in sessions (invalidate refresh tokens)')) {
        Revoke-MgUserSignInSession -UserId $UserId -ErrorAction Stop | Out-Null
        Write-ZtLog "Revoked sign-in sessions for $UserId." -Level INFO
        return [pscustomobject]@{ Action = 'RevokeSessions'; Changed = $true }
    }
    return [pscustomobject]@{ Action = 'RevokeSessions'; Changed = $false; Reason = 'WhatIf' }
}

function Reset-ZtUserPassword {
    <#
        Sets a random password that nobody records, so cached/known credentials stop
        working. Targets standard users; resetting an ADMIN's password via app-only
        auth needs an elevated directory role on the app.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UserId)

    if ($PSCmdlet.ShouldProcess($UserId, 'Reset password to a random, discarded value')) {
        $passwordProfile = @{ Password = (New-ZtPassword -Length 24); ForceChangePasswordNextSignIn = $true }
        Update-MgUser -UserId $UserId -PasswordProfile $passwordProfile -ErrorAction Stop
        Write-ZtLog "Reset password for $UserId (value discarded)." -Level INFO
        return [pscustomobject]@{ Action = 'ResetPassword'; Changed = $true }
    }
    return [pscustomobject]@{ Action = 'ResetPassword'; Changed = $false; Reason = 'WhatIf' }
}

#endregion

#region stage 2: reclaim licenses --------------------------------------------

function Remove-ZtUserLicenses {
    <#
        Removes all assigned SKUs and reports which were reclaimed — the cost-savings
        line. Idempotent: no licenses -> no change.

        Graph permission: User.ReadWrite.All
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UserId)

    $details = Get-MgUserLicenseDetail -UserId $UserId -ErrorAction SilentlyContinue
    if (-not $details) {
        Write-ZtLog "No licenses to reclaim for $UserId." -Level WARN
        return [pscustomobject]@{ Action = 'RemoveLicenses'; Changed = $false; Reclaimed = @() }
    }

    $skuIds    = @($details.SkuId)
    $reclaimed = @($details.SkuPartNumber)

    if ($PSCmdlet.ShouldProcess($UserId, "Remove licenses: $($reclaimed -join ', ')")) {
        Set-MgUserLicense -UserId $UserId -AddLicenses @() -RemoveLicenses $skuIds -ErrorAction Stop | Out-Null
        Write-ZtLog "Reclaimed $($skuIds.Count) license(s) from $UserId : $($reclaimed -join ', ')." -Level INFO
        return [pscustomobject]@{ Action = 'RemoveLicenses'; Changed = $true; Reclaimed = $reclaimed }
    }
    return [pscustomobject]@{ Action = 'RemoveLicenses'; Changed = $false; Reclaimed = $reclaimed; Reason = 'WhatIf' }
}

#endregion

#region stage 3: strip group access ------------------------------------------

function Remove-ZtUserFromGroups {
    <#
        Removes the user from editable security groups. Deliberately SKIPS groups it
        must not (or cannot) touch:
          * dynamic groups          -> membership is rule-driven, not manual
          * on-prem synced groups   -> must be changed in on-prem AD, not the cloud
          * anything in -ExcludeGroupIds (e.g. a litigation-hold group)

        Graph permissions: Group.ReadWrite.All (+ Directory.Read.All if memberOf read is denied)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$UserId,          # object id
        [string[]]$ExcludeGroupIds = @()
    )

    $memberOf = Get-MgUserMemberOf -UserId $UserId -All -ErrorAction SilentlyContinue
    $removed  = @()
    $skipped  = @()

    foreach ($obj in $memberOf) {
        if ($obj.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }

        $g = Get-MgGroup -GroupId $obj.Id `
                -Property Id, DisplayName, GroupTypes, OnPremisesSyncEnabled -ErrorAction SilentlyContinue
        if (-not $g) { continue }

        if ($ExcludeGroupIds -contains $g.Id) {
            Write-ZtLog "Excluded group '$($g.DisplayName)' — leaving membership." -Level WARN
            $skipped += $g.DisplayName; continue
        }
        if ($g.GroupTypes -contains 'DynamicMembership') {
            Write-ZtLog "Skipping dynamic group '$($g.DisplayName)' (rule-driven)." -Level WARN
            $skipped += $g.DisplayName; continue
        }
        if ($g.OnPremisesSyncEnabled) {
            Write-ZtLog "Skipping on-prem synced group '$($g.DisplayName)' (manage in AD)." -Level WARN
            $skipped += $g.DisplayName; continue
        }

        if ($PSCmdlet.ShouldProcess($g.DisplayName, 'Remove user from group')) {
            try {
                Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $UserId -ErrorAction Stop
                Write-ZtLog "Removed user from '$($g.DisplayName)'." -Level INFO
                $removed += $g.DisplayName
            }
            catch {
                Write-ZtLog "Failed to remove from '$($g.DisplayName)': $($_.Exception.Message)" -Level ERROR
            }
        }
    }
    return [pscustomobject]@{ Action = 'RemoveFromGroups'; Changed = ($removed.Count -gt 0); Removed = $removed; Skipped = $skipped }
}

#endregion

#region stage 4: report ------------------------------------------------------

function Send-ZtOffboardingReport {
    <# Emails IT (and optionally the manager) a summary of what was done. Simulated if no key. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToEmail,
        [Parameter(Mandatory)][string]$FromEmail,
        [Parameter(Mandatory)][string]$DepartedUpn,
        [Parameter(Mandatory)][object[]]$Results,
        [string]$TombstonePath
    )

    $apiKey = $null
    try { $apiKey = Get-ZtSecret -Name 'Zt-SendGridKey' } catch { $apiKey = $null }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-ZtLog "No SendGrid key configured. SIMULATING offboarding report to $ToEmail." -Level WARN
        return [pscustomobject]@{ Action = 'Report'; Changed = $false; Simulated = $true; Reason = 'No SendGrid key' }
    }

    $lines = $Results | ForEach-Object {
        $extra =
            if ($_.PSObject.Properties.Name -contains 'Reclaimed' -and $_.Reclaimed) { " [$($_.Reclaimed -join ', ')]" }
            elseif ($_.PSObject.Properties.Name -contains 'Removed' -and $_.Removed) { " [$($_.Removed -join ', ')]" }
            else { '' }
        $status = if ($_.Changed) { 'done' } elseif ($_.PSObject.Properties.Name -contains 'Reason') { $_.Reason } else { 'no change' }
        "  - {0}: {1}{2}" -f $_.Action, $status, $extra
    }

    $body = @"
Offboarding completed for: $DepartedUpn

Actions:
$($lines -join "`n")

Tombstone (pre-state snapshot): $TombstonePath

Reminder: the account is DISABLED and retained, not deleted. Schedule deletion after
the retention period if no data recovery or legal hold is required.
"@

    $payload = @{
        personalizations = @(@{ to = @(@{ email = $ToEmail }) })
        from             = @{ email = $FromEmail; name = 'IT Offboarding' }
        subject          = "Offboarding completed — $DepartedUpn"
        content          = @(@{ type = 'text/plain'; value = $body })
    } | ConvertTo-Json -Depth 10

    $headers = @{ Authorization = "Bearer $apiKey"; 'Content-Type' = 'application/json' }
    try {
        Invoke-RestMethod -Method Post -Uri 'https://api.sendgrid.com/v3/mail/send' -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
        Write-ZtLog "Offboarding report sent to $ToEmail." -Level INFO
        return [pscustomobject]@{ Action = 'Report'; Changed = $true }
    }
    catch {
        Write-ZtLog "Report send failed: $($_.Exception.Message)" -Level ERROR
        return [pscustomobject]@{ Action = 'Report'; Changed = $false; Reason = $_.Exception.Message }
    }
}

#endregion

#region orchestrator ----------------------------------------------------------

function Invoke-ZtOffboarding {
    <#
        Runs the deprovisioning sequence for one departing user. Order is deliberate:
        snapshot -> lock out -> reclaim -> strip groups -> tombstone -> report.

        Honors -WhatIf / -Confirm (they flow down to every changing stage). Pass
        -Confirm:$false for unattended runs. NEVER deletes the account.

        Example:
            Invoke-ZtOffboarding -Identity jdoe@contoso.onmicrosoft.com -WhatIf
            Invoke-ZtOffboarding -Identity jdoe@contoso.onmicrosoft.com -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Identity)

    $cfg = Get-ZtConfig
    $ob  = $cfg.offboarding
    Connect-ZtGraph

    $user = Resolve-ZtUser -Identity $Identity
    Write-ZtLog "=== Offboarding $($user.DisplayName) <$($user.UserPrincipalName)> ===" -Level INFO

    # Single confirmation gate: this orchestrator (ConfirmImpact=High) asks once.
    # Under -WhatIf, ShouldProcess returns $false and we simulate. If an interactive
    # user declines the prompt, we stop here. Once past this gate, nested stages run
    # with -Confirm:$false so they don't re-prompt for every individual action.
    $isWhatIf = $WhatIfPreference -eq $true
    if (-not $isWhatIf) {
        if (-not $PSCmdlet.ShouldProcess($user.UserPrincipalName, 'Offboard user (disable, revoke, reclaim, strip groups)')) {
            Write-ZtLog "Offboarding of $($user.UserPrincipalName) cancelled by operator." -Level WARN
            return [pscustomobject]@{ UserPrincipalName = $user.UserPrincipalName; Cancelled = $true; Actions = @() }
        }
    }

    # Snapshot BEFORE any change — the reversibility / audit anchor.
    $snapshot = Get-ZtUserSnapshot -UserId $user.Id
    $results  = @()

    # -WhatIf and -Confirm do NOT auto-cascade across separately defined functions in
    # PowerShell, so this orchestrator forwards them explicitly to each nested stage.
    # Past the single gate above, -Confirm:$false prevents per-stage re-prompting.
    $results += Disable-ZtUser        -UserId $user.Id -Confirm:$false -WhatIf:$isWhatIf
    $results += Revoke-ZtUserSessions -UserId $user.Id -Confirm:$false -WhatIf:$isWhatIf
    if ($ob.resetPassword) { $results += Reset-ZtUserPassword -UserId $user.Id -Confirm:$false -WhatIf:$isWhatIf }

    # 2. reclaim licenses (the cost-savings step)
    if ($ob.removeAllLicenses) { $results += Remove-ZtUserLicenses -UserId $user.Id -Confirm:$false -WhatIf:$isWhatIf }

    # 3. strip group access
    if ($ob.removeFromAllGroups) {
        $exclusions = @($ob.groupExclusions)
        $results += Remove-ZtUserFromGroups -UserId $user.Id -ExcludeGroupIds $exclusions -Confirm:$false -WhatIf:$isWhatIf
    }

    # Persist tombstone (pre-state + what we did). Skipped cleanly under -WhatIf.
    $tombstone = $null
    if (-not $isWhatIf) {
        $record = [pscustomobject]@{
            Upn      = $user.UserPrincipalName
            UserId   = $user.Id
            PreState = $snapshot
            Actions  = $results
            Note     = 'Account disabled and retained, NOT deleted.'
        }
        $tombstone = Save-ZtTombstone -Upn $user.UserPrincipalName -Record $record
    }

    # 4. report
    if ($ob.reportTo -and -not $isWhatIf) {
        Send-ZtOffboardingReport -ToEmail $ob.reportTo -FromEmail $cfg.senderEmail `
            -DepartedUpn $user.UserPrincipalName -Results $results -TombstonePath $tombstone | Out-Null
    }

    Write-ZtLog "=== Completed offboarding for $($user.UserPrincipalName) (retained, not deleted) ===" -Level INFO
    return [pscustomobject]@{ UserPrincipalName = $user.UserPrincipalName; Tombstone = $tombstone; Actions = $results }
}

#endregion

Export-ModuleMember -Function `
    Resolve-ZtUser, Get-ZtUserSnapshot, Save-ZtTombstone, `
    Disable-ZtUser, Revoke-ZtUserSessions, Reset-ZtUserPassword, `
    Remove-ZtUserLicenses, Remove-ZtUserFromGroups, Send-ZtOffboardingReport, `
    Invoke-ZtOffboarding
