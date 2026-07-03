<#
    Deploy-Azure.ps1
    ----------------
    Idempotent deployment of the ZeroTouch Azure Function. Safe to re-run — it
    creates resources only if they don't already exist, then publishes the code.

    Prereqs: Azure CLI (az), Azure Functions Core Tools v4 (func), and 'az login'
    already done. Fill in your four secrets when prompted (or pass them as params).

    Usage:
        ./scripts/Deploy-Azure.ps1 -StorageAccount stzerotouch<unique>

    The storage account name must be globally unique, lowercase, 3-24 chars.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup   = 'rg-zerotouch',
    [string]$Location        = 'canadacentral',
    [Parameter(Mandatory)][string]$StorageAccount,
    [string]$FunctionApp     = 'func-zerotouch',
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$SendGridKey
)

Set-StrictMode -Version Latest
# NOTE: $ErrorActionPreference = 'Stop' does NOT make PowerShell throw on a failed
# external command (az, func). External processes only ever signal failure via
# $LASTEXITCODE — PowerShell keeps going past a non-zero exit unless you check it
# yourself. Invoke-Az below is that check. Every az/func call in this script goes
# through it — there is no bare "az ..." call left that could fail silently.

function Invoke-Az {
    <# Runs an az CLI command, checks the REAL exit code, throws with the command's
       own stderr on failure. $ArgList is an array so quoting/spacing survives. #>
    param(
        [Parameter(Mandatory)][string[]]$ArgList,
        [switch]$AllowFailure   # for existence checks where a non-zero exit is expected
    )
    $output = & az @ArgList 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "az $($ArgList -join ' ') failed (exit $LASTEXITCODE):`n$output"
    }
    return @{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Wait-ForSubscriptionPropagation {
    <#
        New free-trial subscriptions can pass 'az account show' immediately but still
        fail resource creation for a few minutes while Azure Resource Manager finishes
        propagating them internally. Retries storage account creation with backoff
        instead of failing on the first (very possibly transient) error.
    #>
    param([string[]]$CreateArgs, [int]$MaxAttempts = 5, [int]$DelaySeconds = 30)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-Az -ArgList $CreateArgs -AllowFailure
        if ($result.ExitCode -eq 0) { return }

        $isPropagationError = $result.Output -match 'SubscriptionNotFound|MissingSubscriptionRegistration'
        if (-not $isPropagationError -or $attempt -eq $MaxAttempts) {
            throw "az $($CreateArgs -join ' ') failed after $attempt attempt(s):`n$($result.Output)"
        }
        Write-Host "Subscription still propagating (attempt $attempt/$MaxAttempts). Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $DelaySeconds
    }
}

Write-Host "== ZeroTouch Azure deployment ==" -ForegroundColor Cyan

# 0. Sanity: logged in?
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not logged in. Run 'az login' first." }
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Gray

# 1. Resource group
$groupCheck = Invoke-Az -ArgList @('group', 'exists', '--name', $ResourceGroup) -AllowFailure
if ($groupCheck.Output -eq 'true') {
    Write-Host "Resource group '$ResourceGroup' exists." -ForegroundColor Gray
} else {
    Invoke-Az -ArgList @('group', 'create', '--name', $ResourceGroup, '--location', $Location) | Out-Null
    Write-Host "Created resource group '$ResourceGroup'." -ForegroundColor Green
}

# 2. Storage account (retries on subscription-propagation lag)
$stCheck = Invoke-Az -ArgList @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup) -AllowFailure
if ($stCheck.ExitCode -eq 0) {
    Write-Host "Storage account '$StorageAccount' exists." -ForegroundColor Gray
} else {
    Wait-ForSubscriptionPropagation -CreateArgs @(
        'storage', 'account', 'create', '--name', $StorageAccount, '--resource-group', $ResourceGroup,
        '--location', $Location, '--sku', 'Standard_LRS'
    )
    # Verify it's actually there now — don't just trust the create call's exit code.
    $verify = Invoke-Az -ArgList @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroup) -AllowFailure
    if ($verify.ExitCode -ne 0) { throw "Storage account '$StorageAccount' still not found after creation reported success. Aborting." }
    Write-Host "Created storage account '$StorageAccount'." -ForegroundColor Green
}

# 3. Function App (PowerShell 7.4, Consumption plan, Functions v4)
$faCheck = Invoke-Az -ArgList @('functionapp', 'show', '--name', $FunctionApp, '--resource-group', $ResourceGroup) -AllowFailure
if ($faCheck.ExitCode -eq 0) {
    Write-Host "Function App '$FunctionApp' exists." -ForegroundColor Gray
} else {
    Invoke-Az -ArgList @(
        'functionapp', 'create', '--resource-group', $ResourceGroup,
        '--consumption-plan-location', $Location,
        '--runtime', 'powershell', '--runtime-version', '7.4',
        '--functions-version', '4', '--name', $FunctionApp,
        '--storage-account', $StorageAccount
    ) | Out-Null
    # Verify — don't trust a zero exit code alone; confirm the resource is queryable.
    $verify = Invoke-Az -ArgList @('functionapp', 'show', '--name', $FunctionApp, '--resource-group', $ResourceGroup) -AllowFailure
    if ($verify.ExitCode -ne 0) { throw "Function App '$FunctionApp' still not found after creation reported success. Aborting." }
    Write-Host "Created Function App '$FunctionApp'." -ForegroundColor Green
}

# 4. App Settings (the four secrets). Prompt for any not provided.
if (-not $TenantId)     { $TenantId     = Read-Host 'Zt_TenantId (GUID)' }
if (-not $ClientId)     { $ClientId     = Read-Host 'Zt_ClientId (GUID)' }
if (-not $ClientSecret) { $ClientSecret = Read-Host 'Zt_ClientSecret VALUE' }
if (-not $SendGridKey)  { $SendGridKey  = Read-Host 'Zt_SendGridKey (Enter to skip)' }

$settings = @(
    "Zt_TenantId=$TenantId",
    "Zt_ClientId=$ClientId",
    "Zt_ClientSecret=$ClientSecret"
)
if ($SendGridKey) { $settings += "Zt_SendGridKey=$SendGridKey" }

Invoke-Az -ArgList (@('functionapp', 'config', 'appsettings', 'set', '--name', $FunctionApp, '--resource-group', $ResourceGroup, '--settings') + $settings) | Out-Null
Write-Host "App settings applied." -ForegroundColor Green

# 5. Populate shared/ then publish
& (Join-Path $PSScriptRoot 'Copy-Engine.ps1')

Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'azure-function')
try {
    func azure functionapp publish $FunctionApp
    if ($LASTEXITCODE -ne 0) { throw "func azure functionapp publish failed (exit $LASTEXITCODE). See output above." }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Deployed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Get the function key with:" -ForegroundColor Cyan
Write-Host "  az functionapp function keys list --name $FunctionApp --resource-group $ResourceGroup --function-name LifecycleHttp" -ForegroundColor Gray
Write-Host ""
Write-Host "Then add your Flutter origin to CORS, e.g.:" -ForegroundColor Cyan
Write-Host "  az functionapp cors add --name $FunctionApp --resource-group $ResourceGroup --allowed-origins https://your-app.pages.dev" -ForegroundColor Gray