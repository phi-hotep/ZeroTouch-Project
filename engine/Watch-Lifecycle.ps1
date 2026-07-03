<#
    Watch-Lifecycle.ps1
    -------------------
    Optional CSV-polling trigger (the alternative to the Azure Function). Polls ONE
    intake form (published CSV) whose first column is "Action" (Joiner / Mover /
    Leaver) and routes each new row to the right workflow.

    Use this only if you are NOT using the Azure Function trigger. The Function
    (azure-function/LifecycleHttp/run.ps1) is the primary, real-time trigger.

    Run once (Task Scheduler / cron):
        ./Watch-Lifecycle.ps1
    Loop every 5 minutes:
        ./Watch-Lifecycle.ps1 -PollSeconds 300

    Idempotency: a processed-keys state file + the engine's own idempotent stages.
    Leavers are date-gated against their last working day. Unattended -> -Confirm:$false.
#>
[CmdletBinding()]
param([int]$PollSeconds = 0)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ZeroTouch.Common.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot 'ZeroTouchLifecycle.psm1')  -Force

$cfg = Get-ZtConfig
$lifecycleCfg = Get-ZtProp $cfg 'lifecycle'
$formCfg = if ($lifecycleCfg) { Get-ZtProp $lifecycleCfg 'form' } else { $null }
if (-not $formCfg) {
    throw "config.json has no 'lifecycle.form' section. See config.sample.json."
}
$lc  = $formCfg
$map = $lc.columnMap

# State file goes to a WRITABLE dir (not $PSScriptRoot, which may be read-only).
$stateDir  = Get-ZtWritableDir -SubDir 'state'
$stateFile = if ($stateDir) { Join-Path $stateDir 'processed-lifecycle.json' } else { $null }
$processed = if ($stateFile -and (Test-Path $stateFile)) {
    @(Get-Content $stateFile -Raw | ConvertFrom-Json)
} else { @() }

function Get-RowKey {
    param($Row, $Map)
    # action + whichever identity field applies makes each submission unique
    $idPart = "$($Row.($Map.personalEmail))$($Row.($Map.identity))"
    "$($Row.($Map.timestamp))|$($Row.($Map.action))|$idPart"
}

do {
    try {
        $raw  = (Invoke-WebRequest -Uri $lc.csvUrl -UseBasicParsing -ErrorAction Stop).Content
        $rows = $raw | ConvertFrom-Csv
    }
    catch {
        Write-ZtLog "Failed to fetch lifecycle CSV: $($_.Exception.Message)" -Level ERROR
        $rows = @()
    }

    $today = (Get-Date).Date
    foreach ($row in $rows) {
        $key = Get-RowKey -Row $row -Map $map
        if ($processed -contains $key) { continue }

        $action = "$($row.($map.action))".Trim()
        if ($action -notin @('Joiner', 'Mover', 'Leaver')) {
            Write-ZtLog "Skipping row with unknown action '$action' (key '$key')." -Level WARN
            continue
        }

        # Date gate for leavers: don't act before the last working day.
        if ($action -eq 'Leaver' -and $map.PSObject.Properties.Name -contains 'lastDay') {
            $lastDay = $row.($map.lastDay)
            $eff = [datetime]::MinValue
            if ($lastDay -and [datetime]::TryParse([string]$lastDay, [ref]$eff) -and $eff.Date -gt $today) {
                Write-ZtLog "Leaver $($row.($map.identity)) dated $($eff.ToString('yyyy-MM-dd')) — holding." -Level INFO
                continue
            }
        }

        $request = [pscustomobject]@{
            Action        = $action
            FirstName     = $row.($map.firstName)
            LastName      = $row.($map.lastName)
            Department    = $row.($map.department)
            JobTitle      = $row.($map.jobTitle)
            PersonalEmail = $row.($map.personalEmail)
            Identity      = $row.($map.identity)
            NewDepartment = $row.($map.newDepartment)
        }

        try {
            Invoke-ZtLifecycle -Request $request -Confirm:$false | Out-Null
            $processed += $key
            if ($stateFile) { $processed | ConvertTo-Json | Set-Content $stateFile }
        }
        catch {
            Write-ZtLog "Lifecycle '$action' failed (key '$key'): $($_.Exception.Message)" -Level ERROR
        }
    }

    if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
}
while ($PollSeconds -gt 0)
