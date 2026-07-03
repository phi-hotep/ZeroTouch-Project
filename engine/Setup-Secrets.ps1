<#
    Setup-Secrets.ps1
    -----------------
    One-time local setup. Stores the four secrets in an encrypted local SecretStore
    vault. Values are prompted (never typed into the repo, never echoed to disk in
    plaintext). This is for LOCAL runs only — in Azure the same four values are set
    as Function App App Settings (see azure-function/README.md).

    Prereqs:
        Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser
        Install-Module Microsoft.PowerShell.SecretStore       -Scope CurrentUser

    Run once:
        ./Setup-Secrets.ps1
#>
#Requires -Modules Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
[CmdletBinding()]
param([string]$VaultName = 'ZeroTouch')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue)) {
    Register-SecretVault -Name $VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
    Write-Host "Registered vault '$VaultName'." -ForegroundColor Green
}

$tenantId     = Read-Host 'Entra tenant ID (GUID)'
$clientId     = Read-Host 'App (client) ID (GUID)'
$clientSecret = Read-Host 'App client secret VALUE' -AsSecureString
$sendGridKey  = Read-Host 'SendGrid API key (press Enter to skip email)' -AsSecureString

Set-Secret -Name 'Zt-TenantId'     -Secret $tenantId     -Vault $VaultName
Set-Secret -Name 'Zt-ClientId'     -Secret $clientId     -Vault $VaultName
Set-Secret -Name 'Zt-ClientSecret' -Secret $clientSecret -Vault $VaultName

# Only store the SendGrid key if one was actually provided.
$sgPlain = [System.Net.NetworkCredential]::new('', $sendGridKey).Password
if (-not [string]::IsNullOrWhiteSpace($sgPlain)) {
    Set-Secret -Name 'Zt-SendGridKey' -Secret $sendGridKey -Vault $VaultName
    Write-Host "Stored 4 secrets in vault '$VaultName'." -ForegroundColor Green
} else {
    Write-Host "Stored 3 secrets in vault '$VaultName' (SendGrid skipped — email will SIMULATE)." -ForegroundColor Green
}

Write-Host ""
Write-Host "For unattended runs (Task Scheduler / cron) you can disable the vault password prompt:" -ForegroundColor Yellow
Write-Host "    Set-SecretStoreConfiguration -Authentication None -Interaction None" -ForegroundColor Yellow
Write-Host "Only do that on a machine you trust — it makes the vault readable without a master password." -ForegroundColor Yellow
