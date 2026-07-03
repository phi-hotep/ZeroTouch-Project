# profile.ps1
# Runs ONCE per cold start of each PowerShell worker. Loads the engine so it's
# ready for every invocation the worker handles. On a warm worker, invocations
# reuse the already-loaded module and the existing Graph context.

Set-StrictMode -Version Latest

# The deployed code (wwwroot) is READ-ONLY. Point file logging + tombstones at a
# writable temp folder. The console log is always captured by Application Insights
# regardless, so this is a convenience, not a dependency.
$env:ZT_LOG_DIR = Join-Path $env:TEMP 'zerotouch'

# Load the unified router (which cascades to Common + Onboarding + Offboarding).
# $PSScriptRoot here is the Function App root, so the engine lives in ./shared.
$enginePath = Join-Path $PSScriptRoot 'shared/ZeroTouchLifecycle.psm1'
if (Test-Path $enginePath) {
    Import-Module $enginePath -Force
    Write-Host "ZeroTouch: engine loaded (profile.ps1)."
} else {
    Write-Host "ZeroTouch: WARNING — engine not found at $enginePath. Did you copy engine/*.psm1 + config.json into shared/ before deploying?"
}

# Graph connection is made on demand inside Invoke-ZtLifecycle (Connect-ZtGraph is
# idempotent and reuses the context on a warm worker).
