using namespace System.Net

# run.ps1 — HTTP entry point. Receives the POST JSON from the Flutter page,
# validates it, routes to Invoke-ZtLifecycle, and returns a structured JSON result.
param($Request, $TriggerMetadata)

Set-StrictMode -Version Latest

# Safety net: profile.ps1 already loaded the engine at cold start. This -Force import
# is idempotent and covers the rare case where the profile didn't run. $PSScriptRoot
# is the LifecycleHttp/ folder, so the engine is one level up in ../shared.
$enginePath = Join-Path $PSScriptRoot '../shared/ZeroTouchLifecycle.psm1'
Import-Module $enginePath -Force -ErrorAction SilentlyContinue

$validActions = @('Joiner', 'Mover', 'Leaver')

function Write-JsonResponse {
    param([HttpStatusCode]$Status, $Payload)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $Status
            Headers    = @{ 'Content-Type' = 'application/json; charset=utf-8' }
            Body       = ($Payload | ConvertTo-Json -Depth 8)
        })
}

# Safe property reader that works for BOTH shapes the JSON body can arrive as:
#   - Hashtable / IDictionary  <- what the Azure Functions PowerShell worker actually
#                                 produces for an application/json request body
#   - PSCustomObject           <- what a manual ConvertFrom-Json produces
# .PSObject.Properties[$Name] alone only finds the SECOND shape: a Hashtable's
# PSObject.Properties reflects the Hashtable TYPE's own members (Keys, Values, Count),
# not its dynamic key/value pairs, so that lookup silently returns nothing for a
# Hashtable body — this was a real bug caught during Phase 3 testing (every request
# read action as empty regardless of what was actually sent).
function Get-BodyProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($key in $Obj.Keys) {
            if ($key -ieq $Name) { return $Obj[$key] }
        }
        return $null
    }

    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

try {
    # The runtime usually deserializes JSON already; handle a raw string too.
    $body = $Request.Body
    if ($body -is [string] -and $body) { $body = $body | ConvertFrom-Json }
    if (-not $body) {
        Write-JsonResponse ([HttpStatusCode]::BadRequest) @{ ok = $false; error = 'Empty request body.' }
        return
    }

    $action = "$(Get-BodyProp $body 'action')".Trim()
    if ($action -notin $validActions) {
        Write-JsonResponse ([HttpStatusCode]::BadRequest) @{ ok = $false; error = "Invalid action: '$action'. Expected Joiner, Mover, or Leaver." }
        return
    }

    # Server-side required-field validation (defence in depth, in addition to Flutter).
    $missing = @()
    switch ($action) {
        'Joiner' { foreach ($f in 'firstName', 'lastName', 'department', 'personalEmail') { if (-not (Get-BodyProp $body $f)) { $missing += $f } } }
        'Mover'  { foreach ($f in 'identity', 'newDepartment') { if (-not (Get-BodyProp $body $f)) { $missing += $f } } }
        'Leaver' { foreach ($f in 'identity') { if (-not (Get-BodyProp $body $f)) { $missing += $f } } }
    }
    if ($missing.Count) {
        Write-JsonResponse ([HttpStatusCode]::BadRequest) @{ ok = $false; error = "Missing fields: $($missing -join ', ')." }
        return
    }

    # Future-dated Leaver -> don't run now. The real-time equivalent of the watcher's
    # date gate: a scheduled function (DepartureScheduler, see README) processes the
    # departure on its effective date.
    $lastDay = Get-BodyProp $body 'lastDay'
    if ($action -eq 'Leaver' -and $lastDay) {
        $eff = [datetime]::MinValue
        if ([datetime]::TryParse([string]$lastDay, [ref]$eff) -and $eff.Date -gt (Get-Date).Date) {
            Write-JsonResponse ([HttpStatusCode]::Accepted) @{
                ok        = $true
                scheduled = $true
                message   = "Departure scheduled for $($eff.ToString('yyyy-MM-dd')). It will be processed on the effective date."
            }
            return
        }
    }

    $request = [pscustomobject]@{
        Action           = $action
        FirstName        = Get-BodyProp $body 'firstName'
        LastName         = Get-BodyProp $body 'lastName'
        Department       = Get-BodyProp $body 'department'
        JobTitle         = Get-BodyProp $body 'jobTitle'
        PersonalEmail    = Get-BodyProp $body 'personalEmail'
        Identity         = Get-BodyProp $body 'identity'
        NewDepartment    = Get-BodyProp $body 'newDepartment'
        # Mover only. Absent/false = additive-only (old-department access kept).
        # True = also strip old-department access in the same operation.
        RemoveStaleAccess = [bool](Get-BodyProp $body 'removeStaleAccess')
    }

    # -Confirm:$false is REQUIRED here: the Function host is non-interactive, and the
    # Leaver path is ConfirmImpact=High. The router forwards this down to the nested
    # workflow so nothing prompts.
    $result = Invoke-ZtLifecycle -Request $request -Confirm:$false

    Write-JsonResponse ([HttpStatusCode]::OK) @{ ok = $true; action = $action; result = $result }
}
catch {
    # Also visible in Application Insights via the console.
    Write-Host "ERROR LifecycleHttp: $($_.Exception.Message)"
    Write-JsonResponse ([HttpStatusCode]::InternalServerError) @{ ok = $false; error = $_.Exception.Message }
}
