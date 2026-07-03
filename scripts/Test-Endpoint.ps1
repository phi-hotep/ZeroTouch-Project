<#
    Test-Endpoint.ps1
    -----------------
    Smoke-tests the LifecycleHttp endpoint (local or deployed) for all three JML
    actions plus a future-dated Leaver. Prints the HTTP status and JSON body of each.

    Local:
        ./scripts/Test-Endpoint.ps1 -BaseUrl http://localhost:7071/api/LifecycleHttp

    Deployed:
        ./scripts/Test-Endpoint.ps1 `
            -BaseUrl https://func-zerotouch.azurewebsites.net/api/LifecycleHttp `
            -FunctionKey <key>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [string]$FunctionKey,
    [string]$TestDomain = 'phihotepoutlook.onmicrosoft.com'
)

Set-StrictMode -Version Latest

$headers = @{ 'Content-Type' = 'application/json' }
if ($FunctionKey) { $headers['x-functions-key'] = $FunctionKey }

function Invoke-Case {
    param([string]$Name, [hashtable]$Body)
    Write-Host "`n--- $Name ---" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri $BaseUrl -Method Post -Headers $headers `
            -Body ($Body | ConvertTo-Json) -SkipHttpErrorCheck
        Write-Host "HTTP $($resp.StatusCode)" -ForegroundColor Yellow
        Write-Host $resp.Content
    }
    catch {
        Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$stamp = Get-Date -Format 'HHmmss'

Invoke-Case 'Joiner' @{
    action        = 'Joiner'
    firstName     = 'Ada'
    lastName      = "Test$stamp"
    department    = 'Engineering'
    jobTitle      = 'Developer'
    personalEmail = 'ada@example.com'
}

Invoke-Case 'Mover' @{
    action        = 'Mover'
    identity      = "ada.test$stamp@$TestDomain"
    newDepartment = 'Sales'
}

Invoke-Case 'Leaver (immediate)' @{
    action   = 'Leaver'
    identity = "ada.test$stamp@$TestDomain"
}

Invoke-Case 'Leaver (future — should return scheduled:true, no change)' @{
    action   = 'Leaver'
    identity = "someone@$TestDomain"
    lastDay  = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')
}

Invoke-Case 'Invalid action (should return 400)' @{
    action = 'Bogus'
}

Write-Host "`nDone." -ForegroundColor Green
