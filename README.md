# ZeroTouch — Identity Lifecycle Engine

[![CI](https://github.com/phi-hotep/ZeroTouch-Project/actions/workflows/ci.yml/badge.svg)](https://github.com/phi-hotep/ZeroTouch-Project/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-14B8A6.svg)](LICENSE)
[![Live Demo](https://img.shields.io/badge/demo-zerotouch.huguesbomokin.ca-0F6E56.svg)](https://zerotouch.huguesbomokin.ca)

![ZeroTouch thumbnail](docs/zerotouch-thumbnail.png)

**Live demo:** [zerotouch.huguesbomokin.ca](https://zerotouch.huguesbomokin.ca)

In any company, when someone joins, changes departments, or leaves, IT has to
create their account, set their access, and shut everything down cleanly on
exit. Done by hand, that process is slow and error-prone, and a missed
offboarding step is a real security risk. ZeroTouch automates all three flows
end to end, live against a real Microsoft Entra ID tenant.

Automated **Joiner / Mover / Leaver** (JML) identity lifecycle management on
Microsoft Entra ID, driven by a single Flutter web form and a serverless
PowerShell Azure Function.

A new hire, department transfer, or departure is submitted once; the engine
creates or updates the Entra ID account, assigns or reclaims M365 licenses,
manages security-group membership, and emails the relevant party — with zero
manual IT intervention.

---

## Architecture

```
 Flutter web form  ──POST JSON──►  Azure Function (PowerShell 7)  ──►  ZeroTouch engine
 (Joiner/Mover/Leaver)             LifecycleHttp/run.ps1               Invoke-ZtLifecycle
                                                                            │
                                          ┌─────────────────────────────────┼─────────────────────────────────┐
                                          ▼                                 ▼                                 ▼
                                    Invoke-ZtOnboarding              Invoke-ZtMove                    Invoke-ZtOffboarding
                                    (create, license,               (dept change,                    (disable, revoke,
                                     groups, welcome)                grant access)                    reclaim, strip, report)
                                          └─────────────────────────────────┼─────────────────────────────────┘
                                                                            ▼
                                                          Microsoft Graph · SendGrid · App Insights
```

The engine is trigger-agnostic: the same modules run whether called by the
Azure Function (real-time) or the optional CSV watcher. Only the trigger layer
differs.

---

## Repository layout

```
ZeroTouch-Project/
├── engine/                     PowerShell engine (the core logic)
│   ├── ZeroTouch.Common.psm1          shared helpers (log, config, secrets, Graph, password)
│   ├── ZeroTouchOnboarding.psm1       Joiner pipeline
│   ├── ZeroTouchOffboarding.psm1      Leaver pipeline
│   ├── ZeroTouchLifecycle.psm1        JML router + Mover
│   ├── Invoke-Lifecycle.ps1           CLI (Joiner runs; Mover/Leaver dry-run unless -Execute)
│   ├── Watch-Lifecycle.ps1            optional CSV-polling trigger
│   ├── Setup-Secrets.ps1              one-time local secret vault setup
│   └── config.sample.json             copy to config.json and fill in
│
├── azure-function/             HTTP trigger layer (deploy target)
│   ├── host.json                      Functions v4 config + App Insights sampling
│   ├── profile.ps1                    cold-start: sets ZT_LOG_DIR, loads the engine
│   ├── requirements.psd1              5 targeted Graph submodules
│   ├── local.settings.sample.json     copy to local.settings.json, fill in 4 secrets
│   ├── shared/                        populated at deploy time (Copy-Engine.ps1)
│   └── LifecycleHttp/
│       ├── function.json              HTTP trigger binding (POST)
│       └── run.ps1                    validate → route → JSON response
│
├── flutter-intake/             web form (Phase 5)
│   ├── pubspec.yaml
│   ├── analysis_options.yaml
│   ├── web/                           index.html, manifest.json
│   ├── test/                          JSON-contract unit tests
│   └── lib/
│       ├── main.dart                          ProviderScope + MaterialApp
│       ├── models/lifecycle_request.dart       request model + JSON contract
│       ├── services/lifecycle_api.dart         HTTP client
│       ├── providers/submission_provider.dart  Riverpod AsyncNotifier
│       ├── pages/intake_page.dart              form + conditional fields
│       └── theme/app_theme.dart                Material 3, teal seed #0F6E56
│
├── scripts/                    deployment automation
│   ├── Copy-Engine.ps1                populate azure-function/shared/
│   ├── Deploy-Azure.ps1               idempotent provision + publish
│   └── Test-Endpoint.ps1              smoke-test all three actions
│
├── docs/
│   ├── DEPLOYMENT.md                  full step-by-step runbook
│   └── OFFBOARDING.md                 destructive-action design notes
│
└── .github/workflows/ci.yml    Flutter analyze/test + PSScriptAnalyzer
```

---

## Quick start

### 1. Prerequisites
PowerShell 7+, Azure CLI, Azure Functions Core Tools v4, Node.js 20+, Flutter
SDK, and an Azure account. Verify: `pwsh --version`, `az --version`,
`func --version`, `node --version`, `flutter --version`.

### 2. Entra ID setup (one-time, in the portal)
App registration with three application Graph permissions — `User.ReadWrite.All`,
`Group.ReadWrite.All`, `Organization.Read.All` — plus admin consent, a client
secret, security groups, and a license SKU. See `docs/DEPLOYMENT.md` §Phase 1.

### 3. Configure
```powershell
cd engine
Copy-Item config.sample.json config.json
# edit config.json: upnDomain, group object ids, licenseSkuPartNumber, senderEmail
./Setup-Secrets.ps1          # stores the 4 secrets in the local vault
```

### 4. Prove the engine locally
```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, `
  Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, `
  Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser

./Invoke-Lifecycle.ps1 -Action Joiner -FirstName Ada -LastName Byron `
  -Department Engineering -JobTitle Developer -PersonalEmail ada@example.com
```
Re-run it: the second run changes nothing (idempotency proof). Try a Leaver
dry-run — it makes **no** changes until you add `-Execute`:
```powershell
./Invoke-Lifecycle.ps1 -Action Leaver -Identity ada.byron@yourtenant.onmicrosoft.com
```

### 5. Run the Function locally
```powershell
./scripts/Copy-Engine.ps1                          # populate shared/
cd azure-function
Copy-Item local.settings.sample.json local.settings.json   # fill in the 4 secrets
func start
# in another terminal:
./scripts/Test-Endpoint.ps1 -BaseUrl http://localhost:7071/api/LifecycleHttp
```

### 6. Deploy
```powershell
az login
./scripts/Deploy-Azure.ps1 -StorageAccount stzerotouch<unique>
```

### 7. Connect Flutter
```powershell
cd flutter-intake
flutter pub get
flutter run -d chrome `
  --dart-define=FUNCTION_URL=https://func-zerotouch.azurewebsites.net/api/LifecycleHttp `
  --dart-define=FUNCTION_KEY=<function-key>
```

Full details, troubleshooting, and the production hardening path (Key Vault +
managed identity, Easy Auth instead of a function key) are in
`docs/DEPLOYMENT.md`.

---

## Design highlights

- **Idempotent at every stage.** Re-submitting the same Joiner/Mover/Leaver is
  safe; each stage checks current state before acting.
- **Free-tier aware.** If no license SKU exists in the tenant, the license stage
  logs `SIMULATING` and continues rather than erroring — the code path is proven
  without a paid license.
- **Lock-out first (Leaver).** Disable + session-revocation happen before
  anything else, so the account is dead the instant the run starts even if a
  later stage fails.
- **Never hard-deletes.** Leavers are disabled and retained with a full
  pre-state tombstone; deletion is a separate, manually gated step.
- **Read-only-filesystem safe.** All file writes (logs, tombstones, watcher
  state) route through `Get-ZtWritableDir`, which honours `ZT_LOG_DIR` and
  degrades gracefully — essential on Azure's read-only wwwroot.
- **Correct `-WhatIf` / `-Confirm` propagation.** The router forwards these
  explicitly to nested workflows (PowerShell does not cascade them
  automatically), so dry-runs are truly non-destructive and the non-interactive
  Function never hangs on a confirmation prompt.
- **Defence in depth.** Client-side validation in Flutter *and* server-side
  validation in `run.ps1`.

---

## Security notes

- Secrets never live in the repo. Locally they're in an encrypted SecretStore
  vault; in Azure they're App Settings (env vars). `config.json` and
  `local.settings.json` are gitignored.
- A browser-embedded function key is not a true secret. It is compiled into
  the shipped `main.dart.js` via `--dart-define`, which means it is visible to
  anyone who inspects the JavaScript. That is an acceptable, deliberate
  trade-off for a portfolio demo against a personal test tenant, not a
  production pattern. For production, switch to Entra ID authentication (Easy
  Auth) with OIDC sign-in, or Key Vault + managed identity for the client
  secret. See `docs/DEPLOYMENT.md`.
- **Deployed is not served.** After redeploying the Flutter web build with
  `wrangler pages deploy`, the custom domain can keep serving stale cached
  JS/HTML until the Cloudflare cache is purged (Caching → Configuration →
  Purge Everything) or the site is checked in an incognito window. This is now
  a standing step in the deploy checklist.
- This project runs against a personal test tenant
  (`phihotepoutlook.onmicrosoft.com`) with no real organizational data. The
  tenant ID and app registration client ID are identifiers, not credentials,
  and are not sensitive on their own.

---

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, learn from it.
