<#
    Copy-Engine.ps1
    ---------------
    Copies the PowerShell engine modules + your filled-in config.json into
    azure-function/shared/ so the Function App can load them. Run this before
    'func start' (local) or 'func azure functionapp publish' (deploy), and any
    time you change an engine module.

    Usage (from the repo root or scripts/):
        ./scripts/Copy-Engine.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path $PSScriptRoot -Parent
$engineDir  = Join-Path $repoRoot 'engine'
$sharedDir  = Join-Path $repoRoot 'azure-function/shared'

if (-not (Test-Path $sharedDir)) { New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null }

# Copy the four modules (not the CLI/watcher scripts — the Function only needs the engine).
$modules = 'ZeroTouch.Common.psm1', 'ZeroTouchOnboarding.psm1', 'ZeroTouchOffboarding.psm1', 'ZeroTouchLifecycle.psm1'
foreach ($m in $modules) {
    $src = Join-Path $engineDir $m
    if (-not (Test-Path $src)) { throw "Missing engine module: $src" }
    Copy-Item $src $sharedDir -Force
    Write-Host "Copied $m" -ForegroundColor Green
}

# Copy config.json (your filled-in one, NOT the sample).
$configSrc = Join-Path $engineDir 'config.json'
if (Test-Path $configSrc) {
    Copy-Item $configSrc $sharedDir -Force
    Write-Host "Copied config.json" -ForegroundColor Green
} else {
    Write-Host "WARNING: engine/config.json not found. Copy config.sample.json to config.json and fill it in first." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "shared/ is ready. Next: 'cd azure-function; func start' (local) or run scripts/Deploy-Azure.ps1." -ForegroundColor Cyan
