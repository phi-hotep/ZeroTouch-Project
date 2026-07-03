<#
    ZeroTouch.Common.psm1
    ---------------------
    Shared core for the ZeroTouch Identity Lifecycle Engine. Both the onboarding and
    offboarding modules depend on THIS — not on each other. Single source of truth for:

        Write-ZtLog        timestamped console + best-effort file logging
        Get-ZtConfig       loads config.json (cached)
        Get-ZtSecret       vault-first / env-var fallback secret resolution
        Connect-ZtGraph    app-only Microsoft Graph connection (idempotent)
        New-ZtPassword     complex temp password generator
        Get-ZtWritableDir  resolves a writable directory (ZT_LOG_DIR / TEMP / script dir)

    Requires (PowerShell 7+): Microsoft.Graph.* submodules,
    Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore.

    Azure Functions note: the deployed code filesystem (wwwroot) is READ-ONLY. All
    file writes go through Get-ZtWritableDir, which honours the ZT_LOG_DIR environment
    variable (set in profile.ps1) and degrades gracefully — a failed file write never
    aborts a run, because the console log is already captured by Application Insights.
#>

Set-StrictMode -Version Latest

# Module-scoped cache so Get-ZtConfig doesn't re-read/parse the file on every call.
$script:ZtConfigCache = $null

function Get-ZtProp {
    <#
        Safe property read that works whether InputObject is a [pscustomobject] or a
        [Hashtable]/IDictionary. Returns the property's value if present, otherwise the
        supplied default (null by default). Needed because under
        Set-StrictMode -Version Latest, reading a missing property on a [pscustomobject]
        throws — and a plain .PSObject.Properties[$Name] lookup silently fails on a
        Hashtable (it only sees the Hashtable type's own members, not its dynamic keys).
        This one function handles both shapes correctly.
    #>
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($key -ieq $Name) { return $InputObject[$key] }
        }
        return $Default
    }

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Get-ZtWritableDir {
    <#
        Resolves a writable directory for logs / tombstones, in priority order:
          1. $env:ZT_LOG_DIR                  (set by profile.ps1 in Azure)
          2. <system temp>/zerotouch          (works locally and in Azure)
          3. $PSScriptRoot/<SubDir>           (dev fallback on a writable checkout)
        Returns $null if none can be created — callers must treat file logging as
        best-effort and never depend on the return value being non-null.
    #>
    param([string]$SubDir = 'logs')

    $candidates = @()
    if ($env:ZT_LOG_DIR)  { $candidates += (Join-Path $env:ZT_LOG_DIR $SubDir) }
    $sysTemp = [System.IO.Path]::GetTempPath()
    if ($sysTemp)         { $candidates += (Join-Path (Join-Path $sysTemp 'zerotouch') $SubDir) }
    if ($PSScriptRoot)    { $candidates += (Join-Path $PSScriptRoot $SubDir) }

    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            # Confirm we can actually write, not just create the folder.
            $probe = Join-Path $dir '.zt-write-probe'
            [System.IO.File]::WriteAllText($probe, 'ok')
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            return $dir
        }
        catch {
            continue  # try the next candidate
        }
    }
    return $null
}

function Write-ZtLog {
    <#
        Timestamped console logging (always) + best-effort file logging (never fatal).
        Levels: INFO / WARN / ERROR. The console line is what Application Insights
        captures in Azure; the file is a convenience for local runs.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Gray }
    }

    # Best-effort file write. A read-only filesystem (Azure wwwroot) must NOT crash a run.
    try {
        $logDir = Get-ZtWritableDir -SubDir 'logs'
        if ($logDir) {
            $logFile = Join-Path $logDir ('lifecycle-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            Add-Content -Path $logFile -Value $line -ErrorAction Stop
        }
    }
    catch {
        # Swallow — console already carries the message; file logging is optional.
    }
}

function Get-ZtConfig {
    <#
        Loads config.json (gitignored) from beside this module, and caches it.
        Throws a helpful error if missing. Pass -Force to bypass the cache.
    #>
    param([switch]$Force)

    if ($script:ZtConfigCache -and -not $Force) { return $script:ZtConfigCache }

    $path = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $path)) {
        throw "config.json not found next to ZeroTouch.Common.psm1 ($PSScriptRoot). " +
              "Copy config.sample.json to config.json and fill it in."
    }
    $script:ZtConfigCache = Get-Content $path -Raw | ConvertFrom-Json
    return $script:ZtConfigCache
}

function Get-ZtSecret {
    <#
        Resolves a secret from the SecretManagement vault first, then falls back to an
        environment variable (dashes become underscores: Zt-ClientId -> Zt_ClientId).
        In Azure, the four secrets are App Settings (env vars), so the vault is skipped
        and the env-var fallback resolves them. Locally, Setup-Secrets.ps1 stores them
        in the encrypted SecretStore vault.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$AsSecureString
    )

    $value   = $null
    $envName = $Name -replace '-', '_'

    if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
        try { $value = Get-Secret -Name $Name -ErrorAction Stop } catch { $value = $null }
    }
    if ($null -eq $value) {
        $envVal = [Environment]::GetEnvironmentVariable($envName)
        if ($envVal) { $value = $envVal }
    }
    if ($null -eq $value) {
        throw "Secret '$Name' not found in the vault or in environment variable '$envName'. " +
              "Locally: run Setup-Secrets.ps1. In Azure: set it as a Function App App Setting."
    }

    if ($AsSecureString) {
        if ($value -is [securestring]) { return $value }
        return (ConvertTo-SecureString ([string]$value) -AsPlainText -Force)
    }
    if ($value -is [securestring]) {
        return ([System.Net.NetworkCredential]::new('', $value)).Password
    }
    return [string]$value
}

function Connect-ZtGraph {
    <#
        App-only (client credentials) connection to Microsoft Graph. Idempotent:
        reuses the existing context on a warm worker / within the same session.
    #>
    [CmdletBinding()]
    param()

    if (Get-MgContext -ErrorAction SilentlyContinue) { return }  # already connected

    $tenantId = Get-ZtSecret -Name 'Zt-TenantId'
    $clientId = Get-ZtSecret -Name 'Zt-ClientId'
    $secret   = Get-ZtSecret -Name 'Zt-ClientSecret' -AsSecureString
    $cred     = [System.Management.Automation.PSCredential]::new($clientId, $secret)

    Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $cred -NoWelcome -ErrorAction Stop
    Write-ZtLog "Connected to Microsoft Graph (tenant $tenantId)." -Level INFO
}

function New-ZtPassword {
    <# Generates a complex temp password. Excludes ambiguous chars (0/O, 1/l/I). #>
    param([int]$Length = 16)

    if ($Length -lt 8) { $Length = 8 }  # guard: room for one of each class + entropy

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $sym   = '!@#$%^&*-_'
    $all   = $upper + $lower + $digit + $sym

    # guarantee one of each character class
    $chars = [System.Collections.Generic.List[char]]::new()
    $chars.Add($upper[(Get-Random -Maximum $upper.Length)])
    $chars.Add($lower[(Get-Random -Maximum $lower.Length)])
    $chars.Add($digit[(Get-Random -Maximum $digit.Length)])
    $chars.Add($sym[(Get-Random   -Maximum $sym.Length)])

    while ($chars.Count -lt $Length) {
        $chars.Add($all[(Get-Random -Maximum $all.Length)])
    }
    # shuffle so the guaranteed-class chars aren't always in the first four positions
    return (-join ($chars | Sort-Object { Get-Random }))
}

Export-ModuleMember -Function `
    Write-ZtLog, Get-ZtConfig, Get-ZtSecret, Connect-ZtGraph, New-ZtPassword, Get-ZtWritableDir, Get-ZtProp
