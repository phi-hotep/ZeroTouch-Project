<#
    ZeroTouchOnboarding.psm1
    -------------------------
    Joiner pipeline for the ZeroTouch Identity Lifecycle Engine.

    One function per stage so each is independently testable:
        New-ZtUser            -> create the Entra ID (Azure AD) account
        Set-ZtUserLicense     -> assign an M365 license SKU (graceful if none exist)
        Add-ZtUserToGroups    -> add to security groups
        Send-ZtWelcomeEmail   -> SendGrid welcome email
        Invoke-ZtOnboarding   -> orchestrate all four for one new hire

    Shared helpers (logging, config, secrets, Graph connect, password) come from
    ZeroTouch.Common. This module does NOT depend on the offboarding module.

    Graph application permissions: User.ReadWrite.All, Group.ReadWrite.All,
    Organization.Read.All.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ZeroTouch.Common.psm1') -Force

#region stage 1: user creation -----------------------------------------------

function New-ZtUser {
    <#
        Creates an Entra ID user. Idempotent: if the UPN already exists, it is
        returned untouched (Created = $false) so re-runs are safe.

        UsageLocation is set at creation because license assignment FAILS without
        it (Graph requires a usage location before granting any SKU).

        Graph permission: User.ReadWrite.All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$MailNickname,
        [string]$GivenName,
        [string]$Surname,
        [string]$JobTitle,
        [string]$Department,
        [string]$UsageLocation = 'CA'
    )

    $existing = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-ZtLog "User $UserPrincipalName already exists (id $($existing.Id)). Skipping create." -Level WARN
        return [pscustomobject]@{ User = $existing; TempPassword = $null; Created = $false }
    }

    $tempPassword = New-ZtPassword
    $params = @{
        DisplayName       = $DisplayName
        UserPrincipalName = $UserPrincipalName
        MailNickname      = $MailNickname
        AccountEnabled    = $true
        UsageLocation     = $UsageLocation
        PasswordProfile   = @{
            Password                      = $tempPassword
            ForceChangePasswordNextSignIn = $true
        }
    }
    if ($GivenName)  { $params.GivenName  = $GivenName }
    if ($Surname)    { $params.Surname    = $Surname }
    if ($JobTitle)   { $params.JobTitle   = $JobTitle }
    if ($Department) { $params.Department = $Department }

    if (-not $PSCmdlet.ShouldProcess($UserPrincipalName, 'Create Entra ID user')) {
        return [pscustomobject]@{ User = $null; TempPassword = $null; Created = $false }
    }

    $user = New-MgUser @params -ErrorAction Stop
    Write-ZtLog "Created user $UserPrincipalName (id $($user.Id))." -Level INFO
    return [pscustomobject]@{ User = $user; TempPassword = $tempPassword; Created = $true }
}

#endregion

#region stage 2: license assignment ------------------------------------------

function Set-ZtUserLicense {
    <#
        Assigns a license SKU by its SkuPartNumber (e.g. SPE_E5, O365_BUSINESS_ESSENTIALS,
        POWERAPPS_DEV). Idempotent and free-tier aware:

          * SKU not present in tenant         -> log + SIMULATE (no error). Free-tier path:
                                                  the code is proven, the grant is skipped.
          * SKU present but 0 available units -> log + SIMULATE
          * user already holds the SKU        -> skip
          * otherwise                         -> assign

        Graph permissions: User.ReadWrite.All + Organization.Read.All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserId,         # UPN or object id
        [Parameter(Mandatory)][string]$SkuPartNumber
    )

    if ([string]::IsNullOrWhiteSpace($SkuPartNumber)) {
        Write-ZtLog "No licenseSkuPartNumber configured. SIMULATING (no license stage)." -Level WARN
        return [pscustomobject]@{ Assigned = $false; Simulated = $true; Reason = 'No SKU configured' }
    }

    $sku = Get-MgSubscribedSku -All -ErrorAction SilentlyContinue | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }
    if (-not $sku) {
        Write-ZtLog "SKU '$SkuPartNumber' not present in tenant. SIMULATING assignment (free-tier path)." -Level WARN
        return [pscustomobject]@{ Assigned = $false; Simulated = $true; Reason = 'SKU not found in tenant' }
    }

    $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    if ($available -le 0) {
        Write-ZtLog "SKU '$SkuPartNumber' has no free units ($($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) used). SIMULATING." -Level WARN
        return [pscustomobject]@{ Assigned = $false; Simulated = $true; Reason = 'No available units' }
    }

    $current = Get-MgUserLicenseDetail -UserId $UserId -ErrorAction SilentlyContinue
    if ($current -and ($current.SkuId -contains $sku.SkuId)) {
        Write-ZtLog "User $UserId already holds $SkuPartNumber. Skipping." -Level WARN
        return [pscustomobject]@{ Assigned = $true; Simulated = $false; Reason = 'Already assigned' }
    }

    if (-not $PSCmdlet.ShouldProcess($UserId, "Assign license $SkuPartNumber")) {
        return [pscustomobject]@{ Assigned = $false; Simulated = $false; Reason = 'WhatIf' }
    }

    Set-MgUserLicense -UserId $UserId -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
    Write-ZtLog "Assigned $SkuPartNumber to $UserId." -Level INFO
    return [pscustomobject]@{ Assigned = $true; Simulated = $false; Reason = 'Assigned' }
}

#endregion

#region stage 3: group membership --------------------------------------------

function Add-ZtUserToGroups {
    <#
        Adds the user to one or more security groups by object id. Idempotent:
        checks current membership first and skips groups the user is already in.

        Graph permission: Group.ReadWrite.All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserId,          # object id (not UPN)
        [Parameter(Mandatory)][string[]]$GroupIds
    )

    $results = foreach ($gid in $GroupIds) {
        $members = Get-MgGroupMember -GroupId $gid -All -ErrorAction SilentlyContinue
        if ($members -and ($members.Id -contains $UserId)) {
            Write-ZtLog "User already in group $gid. Skipping." -Level WARN
            [pscustomobject]@{ GroupId = $gid; Added = $false; Reason = 'Already a member' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($gid, 'Add user to group')) {
            [pscustomobject]@{ GroupId = $gid; Added = $false; Reason = 'WhatIf' }
            continue
        }
        try {
            $ref = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId" }
            New-MgGroupMemberByRef -GroupId $gid -BodyParameter $ref -ErrorAction Stop
            Write-ZtLog "Added user to group $gid." -Level INFO
            [pscustomobject]@{ GroupId = $gid; Added = $true; Reason = 'Added' }
        }
        catch {
            Write-ZtLog "Failed to add user to group $gid : $($_.Exception.Message)" -Level ERROR
            [pscustomobject]@{ GroupId = $gid; Added = $false; Reason = $_.Exception.Message }
        }
    }
    return $results
}

#endregion

#region stage 4: welcome email -----------------------------------------------

function Send-ZtWelcomeEmail {
    <#
        Sends the welcome email via SendGrid v3 (https://api.sendgrid.com/v3/mail/send).
        FromEmail MUST be a verified sender in SendGrid or the call is rejected.

        If no SendGrid key is configured (Zt-SendGridKey missing/blank), the stage is
        SIMULATED rather than erroring — so local testing and free-tier demos work
        without an email provider. Provider-swappable: only the URL, Bearer header,
        and JSON shape are SendGrid-specific.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ToEmail,
        [Parameter(Mandatory)][string]$ToName,
        [Parameter(Mandatory)][string]$FromEmail,
        [string]$FromName = 'IT Onboarding',
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [string]$TempPassword
    )

    $apiKey = $null
    try { $apiKey = Get-ZtSecret -Name 'Zt-SendGridKey' } catch { $apiKey = $null }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-ZtLog "No SendGrid key configured. SIMULATING welcome email to $ToEmail." -Level WARN
        return [pscustomobject]@{ Sent = $false; Simulated = $true; Reason = 'No SendGrid key' }
    }

    $pwLine = if ($TempPassword) {
        "Temporary password: $TempPassword (you'll pick your own on first sign-in)."
    } else {
        "Your IT administrator will share your temporary password through a secure channel."
    }

    # Plain-text fallback — shown by clients that don't render HTML.
    $bodyText = @"
Hi $ToName,

Good news: your account provisioned itself. No tickets, no waiting on IT,
just a clean, ready-to-go workspace.

Sign-in email: $UserPrincipalName
$pwLine

Sign in: https://www.office.com

If something looks off, reply to this email — a human will pick it up.

Glad to have you here.
"@

    # HTML-encode user-influenced values before embedding in markup (defence in
    # depth — FirstName/LastName ultimately trace back to a form submission).
    $encName = [System.Net.WebUtility]::HtmlEncode($ToName)
    $encUpn  = [System.Net.WebUtility]::HtmlEncode($UserPrincipalName)
    $encPw   = if ($TempPassword) { [System.Net.WebUtility]::HtmlEncode($TempPassword) } else { $null }

    $passwordRowHtml = if ($encPw) {
        @"
              <tr>
                <td style="padding:4px 0;color:#4b5a56;font-size:13px;">Temporary password</td>
              </tr>
              <tr>
                <td style="padding:0 0 4px 0;font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:16px;color:#0F2A22;letter-spacing:0.3px;">$encPw</td>
              </tr>
              <tr>
                <td style="padding:0;color:#7a8a85;font-size:12px;font-style:italic;">You'll pick your own on first sign-in.</td>
              </tr>
"@
    } else {
        @"
              <tr>
                <td style="padding:4px 0;color:#4b5a56;font-size:13px;">Temporary password</td>
              </tr>
              <tr>
                <td style="padding:0;color:#0F2A22;font-size:14px;">Your IT administrator will share it through a secure channel.</td>
              </tr>
"@
    }

    $bodyHtml = @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;padding:0;background-color:#f2f6f4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f2f6f4;padding:32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background-color:#ffffff;border-radius:12px;overflow:hidden;">
          <tr>
            <td style="background-color:#0F6E56;padding:32px 40px;">
              <p style="margin:0;color:#ffffff;font-size:22px;font-weight:600;">You're in, welcome aboard! &#128075;</p>
            </td>
          </tr>
          <tr>
            <td style="padding:32px 40px 8px 40px;">
              <p style="margin:0 0 16px 0;color:#1a1a1a;font-size:15px;line-height:1.6;">Hi $encName,</p>
              <p style="margin:0 0 24px 0;color:#1a1a1a;font-size:15px;line-height:1.6;">
                Good news: your account provisioned itself. No tickets, no waiting on IT,
                just a clean, ready-to-go workspace.
              </p>
            </td>
          </tr>
          <tr>
            <td style="padding:0 40px 24px 40px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#eef5f2;border-left:4px solid #0F6E56;border-radius:8px;">
                <tr>
                  <td style="padding:16px 20px;">
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                      <tr>
                        <td style="padding:0 0 4px 0;color:#4b5a56;font-size:13px;">Sign-in email</td>
                      </tr>
                      <tr>
                        <td style="padding:0 0 12px 0;color:#0F2A22;font-size:16px;font-weight:600;">$encUpn</td>
                      </tr>
$passwordRowHtml
                    </table>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:0 40px 32px 40px;" align="center">
              <a href="https://www.office.com" style="display:inline-block;background-color:#0F6E56;color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:12px 32px;border-radius:6px;">Sign in</a>
            </td>
          </tr>
          <tr>
            <td style="padding:0 40px 32px 40px;">
              <p style="margin:0;color:#4b5a56;font-size:13px;line-height:1.6;">
                If something looks off, reply to this email, a human will pick it up.<br>
                Glad to have you here.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
"@

    $payload = @{
        personalizations = @(@{ to = @(@{ email = $ToEmail; name = $ToName }) })
        from             = @{ email = $FromEmail; name = $FromName }
        subject          = "You're in — welcome aboard!"
        content          = @(
            @{ type = 'text/plain'; value = $bodyText }
            @{ type = 'text/html'; value = $bodyHtml }
        )
    } | ConvertTo-Json -Depth 10

    if (-not $PSCmdlet.ShouldProcess($ToEmail, 'Send welcome email')) {
        return [pscustomobject]@{ Sent = $false; Simulated = $false; Reason = 'WhatIf' }
    }

    $headers = @{ Authorization = "Bearer $apiKey"; 'Content-Type' = 'application/json' }
    try {
        Invoke-RestMethod -Method Post -Uri 'https://api.sendgrid.com/v3/mail/send' -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
        Write-ZtLog "Welcome email queued to $ToEmail." -Level INFO
        return [pscustomobject]@{ Sent = $true; Simulated = $false; Reason = 'Queued (HTTP 202)' }
    }
    catch {
        Write-ZtLog "SendGrid send failed: $($_.Exception.Message)" -Level ERROR
        return [pscustomobject]@{ Sent = $false; Simulated = $false; Reason = $_.Exception.Message }
    }
}

#endregion

#region orchestrator ----------------------------------------------------------

function Invoke-ZtOnboarding {
    <#
        Runs all four stages for one normalized new-hire object:
            $hire = [pscustomobject]@{
                FirstName = 'Ada'; LastName = 'Byron'; Department = 'Engineering';
                JobTitle = 'Developer'; PersonalEmail = 'ada@example.com'
            }
        Each stage is independently idempotent, so the whole pipeline is safe to re-run.
        Supports -WhatIf (flows to every changing stage).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Hire)

    $cfg = Get-ZtConfig
    Connect-ZtGraph

    # Normalize once, StrictMode-safe. JobTitle is optional; the rest are validated
    # upstream (Flutter + run.ps1) but we read them defensively for direct callers.
    $firstName     = Get-ZtProp $Hire 'FirstName'
    $lastName      = Get-ZtProp $Hire 'LastName'
    $department    = Get-ZtProp $Hire 'Department'
    $jobTitle      = Get-ZtProp $Hire 'JobTitle'
    $personalEmail = Get-ZtProp $Hire 'PersonalEmail'

    if (-not $firstName -or -not $lastName) {
        throw "Onboarding requires FirstName and LastName."
    }

    $mailNickname = ($firstName + '.' + $lastName).ToLower() -replace '[^a-z0-9.]', ''
    $upn          = "$mailNickname@$($cfg.upnDomain)"
    $displayName  = "$firstName $lastName"

    Write-ZtLog "=== Onboarding $displayName <$upn> (dept: $department) ===" -Level INFO

    # 1. user
    $u = New-ZtUser -DisplayName $displayName -UserPrincipalName $upn -MailNickname $mailNickname `
                    -GivenName $firstName -Surname $lastName -JobTitle $jobTitle `
                    -Department $department -UsageLocation $cfg.usageLocation

    # Under -WhatIf the user object is null; report the intended UPN and stop.
    if (-not $u.User) {
        Write-ZtLog "WhatIf: would onboard $upn (no further stages simulated)." -Level INFO
        return [pscustomobject]@{ UserPrincipalName = $upn; UserId = $null; Created = $false; WhatIf = $true }
    }
    $userId = $u.User.Id

    # 2. license
    $license = Set-ZtUserLicense -UserId $upn -SkuPartNumber $cfg.licenseSkuPartNumber

    # 3. groups: default groups + any mapped to the department
    $groupIds = @($cfg.defaultGroupIds)
    $deptProp = $cfg.departmentGroupMap.PSObject.Properties | Where-Object Name -EQ $department
    if ($deptProp) { $groupIds += $deptProp.Value }
    $groupIds = $groupIds | Where-Object { $_ -and $_ -notmatch '^0{8}-0{4}-0{4}-0{4}-0{12}$' } | Select-Object -Unique
    $groups = if ($groupIds) { Add-ZtUserToGroups -UserId $userId -GroupIds $groupIds } else { @() }

    # 4. welcome email
    $email = Send-ZtWelcomeEmail -ToEmail $personalEmail -ToName $firstName `
                        -FromEmail $cfg.senderEmail -UserPrincipalName $upn `
                        -TempPassword $u.TempPassword

    Write-ZtLog "=== Completed onboarding for $upn ===" -Level INFO
    return [pscustomobject]@{
        UserPrincipalName = $upn
        UserId            = $userId
        Created           = $u.Created
        License           = $license
        Groups            = $groups
        Email             = $email
    }
}

#endregion

Export-ModuleMember -Function New-ZtUser, Set-ZtUserLicense, Add-ZtUserToGroups, Send-ZtWelcomeEmail, Invoke-ZtOnboarding