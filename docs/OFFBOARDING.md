# ZeroTouch — Offboarding (Leaver) Design Notes

Offboarding is destructive, so the Leaver pipeline follows three rules the
onboarding side doesn't need.

## 1. Lock out first

Order matters: **disable → revoke sessions → reset password**, before touching
licenses or groups. Disabling alone does not kill active refresh tokens, so
`Revoke-ZtUserSessions` runs immediately after `Disable-ZtUser` to make the
lockout real. If a later stage fails, the account is already dead.

## 2. Snapshot before you strip

`Get-ZtUserSnapshot` captures the pre-state (enabled flag, licenses, group
memberships, manager) and `Save-ZtTombstone` persists it **before** any access
is removed. This is the audit and reversibility anchor: to restore access, read
the tombstone and re-add.

Tombstones are written via `Get-ZtWritableDir` (honours `ZT_LOG_DIR`), because
the Azure Functions filesystem is read-only. If no writable location exists, the
full record is emitted to the console and captured by Application Insights, so
the audit trail survives even without file persistence.

For durable retention in production, point `ZT_LOG_DIR` at a mounted Azure File
share, or extend `Save-ZtTombstone` to write to Blob Storage.

## 3. Never hard-delete

The pipeline disables and strips access but **retains** the object. Deletion is
a separate, manually gated action after the configured retention window
(`retentionDays` in `config.json`). Disabling is reversible; deletion is not.

## What gets skipped when stripping groups

`Remove-ZtUserFromGroups` deliberately leaves:

- **Dynamic groups** — membership is rule-driven, not manual.
- **On-prem synced groups** — must be changed in on-prem AD, not the cloud.
- **Excluded groups** — anything in `offboarding.groupExclusions` (e.g. a
  litigation-hold group).

## Confirmation model

Every changing function is `ConfirmImpact = 'High'`. The orchestrator
`Invoke-ZtOffboarding` presents a **single** confirmation gate; once past it,
nested stages run with `-Confirm:$false` so they don't re-prompt for each
action. `-WhatIf` is forwarded to every stage, so a dry run is genuinely
non-destructive.

Non-interactive callers (the Azure Function `run.ps1`, the watcher) pass
`-Confirm:$false` to `Invoke-ZtLifecycle`, which forwards it to the offboarding
orchestrator — no prompt, no hang.

## Future-dated departures

A Leaver with a `lastDay` in the future is not executed immediately:

- **Azure Function:** `run.ps1` returns `{ ok: true, scheduled: true }` (HTTP
  202) without running the pipeline. A scheduled/timer function would process it
  on the effective date.
- **CSV watcher:** `Watch-Lifecycle.ps1` holds the row until `lastDay <= today`.
