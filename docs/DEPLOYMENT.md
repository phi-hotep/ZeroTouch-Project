# ZeroTouch — Deployment Runbook

Step-by-step, command-by-command, from an empty machine to a working production
deployment. Assumes the Microsoft / Azure environment is new to you, so each
cloud step is explicit.

Commands use PowerShell line continuation (backtick `` ` ``). On bash, replace
the trailing backtick with a backslash (`\`).

| Phase | Goal |
|---|---|
| 0 — Prerequisites | Install and verify the five tools |
| 1 — Entra ID | App identity, permissions, groups, a license SKU |
| 2 — Local engine | Prove the engine talks to Graph |
| 3 — Function local | Run the engine inside the Functions host locally |
| 4 — Deploy | Publish the Function to Azure |
| 5 — Flutter | Connect the web form through CORS |
| 6 — SendGrid | Send the welcome email |
| 7 — Host (optional) | Publish the Flutter web build |

---

## Phase 0 — Prerequisites

Install and verify:

```powershell
pwsh --version       # PowerShell 7+ (distinct from Windows PowerShell 5.1)
az --version         # Azure CLI
func --version       # Azure Functions Core Tools v4
node --version       # Node.js 20+
flutter --version    # Flutter SDK
```

Windows: install Azure CLI and Core Tools with `winget`. macOS: `brew install
azure-cli azure-functions-core-tools@4`.

**Checkpoint:** every command prints a version, no "command not found".

---

## Phase 1 — Entra ID setup

In a browser at **entra.microsoft.com** (Identity → Applications → App
registrations):

1. **New registration** → name `ZeroTouch-Onboarding`, single tenant, no
   redirect URI. Copy the **Application (client) ID** and **Directory (tenant)
   ID**.
2. **Certificates & secrets** → New client secret → copy the **VALUE
   immediately** (shown once).
3. **API permissions** → Add → Microsoft Graph → **Application permissions** →
   add `User.ReadWrite.All`, `Group.ReadWrite.All`, `Organization.Read.All`.
4. **Grant admin consent** → all three must show "Granted".
5. **Identity → Groups** → create Security groups (e.g. Engineering, Sales,
   Finance). Copy each **Object ID**.
6. Activate a free license SKU: at **make.powerapps.com**, sign in with a
   **native tenant admin account** (not a personal MSA) and accept the free
   Developer Plan. A `POWERAPPS_DEV` SKU then appears in the tenant.

**Checkpoint:** you have tenant ID, client ID, client secret, three consented
permissions, group object IDs, and a `POWERAPPS_DEV` SKU.

> Admin consent needs the Global Administrator role. If permissions still fail
> after consent, wait 5–15 min for propagation.

---

## Phase 2 — Local engine test

Prove the engine works against Graph from your machine before any cloud work.

```powershell
# 1. Install the targeted Graph submodules + secret vault modules
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, `
  Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, `
  Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.SecretManagement, `
  Microsoft.PowerShell.SecretStore -Scope CurrentUser

cd engine

# 2. Store secrets (prompts for tenant/client/secret/SendGrid)
./Setup-Secrets.ps1

# 3. Fill in config.json
Copy-Item config.sample.json config.json
#   set upnDomain, licenseSkuPartNumber (POWERAPPS_DEV), defaultGroupIds,
#   departmentGroupMap (your group object ids), senderEmail

# 4. Run one Joiner
./Invoke-Lifecycle.ps1 -Action Joiner -FirstName Ada -LastName Byron `
  -Department Engineering -JobTitle Developer -PersonalEmail ada@example.com
```

**Checkpoint:** logs show "Created user", a license assigned (or SIMULATING),
groups added. Re-run → "already exists / already a member" (idempotency). A
Leaver **without** `-Execute` is a dry run and changes nothing.

---

## Phase 3 — Run the Function locally

```powershell
# 1. Copy the engine + your config into the Function's shared/ folder
./scripts/Copy-Engine.ps1

# 2. Local secrets
cd azure-function
Copy-Item local.settings.sample.json local.settings.json
#   fill in Zt_TenantId, Zt_ClientId, Zt_ClientSecret, Zt_SendGridKey

# 3. Start the host
func start

# 4. In another terminal — smoke test all three actions
./scripts/Test-Endpoint.ps1 -BaseUrl http://localhost:7071/api/LifecycleHttp
```

**Checkpoint:** each action returns a structured JSON body. The first call is
slow (cold start while Graph modules load); that's expected.

---

## Phase 4 — Deploy to Azure

```powershell
az login
./scripts/Deploy-Azure.ps1 -StorageAccount stzerotouch<unique>
```

The script idempotently creates the resource group, storage account, and
Function App (PowerShell 7.4, Consumption plan, Functions v4), sets the four
secrets as App Settings, populates `shared/`, and publishes.

Get the URL and function key:
```powershell
az functionapp function keys list --name func-zerotouch `
  --resource-group rg-zerotouch --function-name LifecycleHttp
```

Test the deployed endpoint:
```powershell
./scripts/Test-Endpoint.ps1 `
  -BaseUrl https://func-zerotouch.azurewebsites.net/api/LifecycleHttp `
  -FunctionKey <key>
```

**Checkpoint:** same JSON responses, now from `*.azurewebsites.net`.

---

## Phase 5 — Connect Flutter

```powershell
# Allow the Flutter origin (CORS). Replace PORT with what 'flutter run' prints.
az functionapp cors add --name func-zerotouch --resource-group rg-zerotouch `
  --allowed-origins http://localhost:PORT

cd flutter-intake
flutter pub get
flutter run -d chrome `
  --dart-define=FUNCTION_URL=https://func-zerotouch.azurewebsites.net/api/LifecycleHttp `
  --dart-define=FUNCTION_KEY=<function-key>
```

Submit a Joiner, a Mover, and a Leaver. Each returns a colour-coded SnackBar;
confirm the change in the Entra admin center.

**Checkpoint:** the full chain UI → Function → Graph works.

---

## Phase 6 — SendGrid welcome email

1. Create a SendGrid account (60-day trial, 100 emails/day). Permanently free
   alternatives: Resend or Brevo (the email function is provider-agnostic).
2. Settings → Sender Authentication → Single Sender Verification → verify an
   address. SendGrid rejects unverified senders.
3. Settings → API Keys → create a Restricted Access key with **Mail Send** only.
   Put it in the `Zt_SendGridKey` App Setting; set `senderEmail` in `config.json`
   to the verified address, re-run `Copy-Engine.ps1`, and re-publish.
4. Submit a Joiner and check the personal-email inbox.

**Checkpoint:** the welcome email arrives with the UPN and temporary password.

---

## Phase 7 — Host the Flutter app (optional)

```powershell
flutter build web --release `
  --dart-define=FUNCTION_URL=https://func-zerotouch.azurewebsites.net/api/LifecycleHttp `
  --dart-define=FUNCTION_KEY=<function-key>
```

Deploy `build/web` to Cloudflare Pages, Firebase Hosting, Azure Static Web Apps,
or GitHub Pages. **After hosting, re-run the CORS command with your public URL**,
or the browser will block the calls.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Insufficient privileges (Graph) | Admin consent not granted, or a permission missing. Wait 5–15 min after consent. |
| License stage always SIMULATING | No matching SKU with free units. Set `licenseSkuPartNumber` to `POWERAPPS_DEV`. |
| Cold-start timeout on first call | Confirm `requirements.psd1` lists only the 5 submodules, not the full `Microsoft.Graph`. |
| CORS error in browser console | Run `az functionapp cors add` for the exact Flutter origin. |
| SendGrid 403 / sender not verified | Verify the Single Sender and match `senderEmail` to it. |
| `Get-ZtSecret: secret not found` | App Setting names must be `Zt_TenantId` etc. (underscores). |
| `Get-MgUserMemberOf` denied (Leaver) | Add `Directory.Read.All` to the app and re-consent. |
| Engine not loading in Function | Did you run `Copy-Engine.ps1` before publishing? `shared/` must contain the 4 modules + config.json. |

---

## Production hardening

- **Function key is not a true secret** when embedded in a browser app (visible
  in dev tools). For production, enable **Entra ID authentication (Easy Auth)**
  on the Function App and have Flutter sign the user in with OIDC; the Function
  validates the bearer token — no key to expose.
- **Client secret in plaintext** (App Setting) → move to **Azure Key Vault +
  system-assigned managed identity**, referenced as
  `@Microsoft.KeyVault(SecretUri=...)`. The secret then exists in plaintext
  nowhere.
- **Durable tombstones** → point `ZT_LOG_DIR` at a mounted Azure File share, or
  extend `Save-ZtTombstone` to push to Blob Storage. The console log (App
  Insights) already carries the record as a fallback.
