# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Big Picture

This is a **single-file Terraform project** (`main.tf`, ~850 lines) that provisions a complete Azure application architecture and deploys three Node.js/Express microservices. There are no `package.json` files committed — dependencies are installed at Docker build time via `npm install` in each Dockerfile. Region is `southindia`.

### Architecture (request path)

```
Internet
    │
    ▼
Application Gateway (WAF_v2, public IP, OWASP 3.2 Detection, /health probe)   ← snet-appgateway
    │
    ▼
Frontend Web App (Linux App Service, :80) — public access ENABLED but locked to snet-appgateway   ← snet-webapp
    │  serves HTML UI; proxies /api/publish-event, /api/event-status; renders /api/aggregated-data
    ▼
API Management (Developer_1, Internal VNet mode, private VIP)   ← snet-apim
    │  frontend BACKEND_URL = APIM gateway_url (https://<name>.azure-api.net, resolves to private VIP)
    │  "aggregator-api" forwards POST /api/publish-event, GET /api/event-status, GET /api/aggregated-data
    │  outbound policy stamps X-Served-Via-APIM header → frontend renders a "Routed through APIM" badge
    ▼
Aggregator Backend / Service B (Container App, :80, EXTERNAL ingress = VNet-visible, not public)
    │  publishes events to Service Bus; proxies /api/event-status and /api/aggregated-data to Backend A
    ├──→ Azure Service Bus (topic: demo-events, subscription: demo-processor)  via private endpoint  ← snet-pe
    ▼
Backend / Service A (Container App, :80, INTERNAL ingress)   ← snet-cae
    │  fetches weather from MET Norway API, receives Service Bus messages
    └──→ api.met.no (outbound via NAT Gateway static IP)
```

> **APIM routing:** `azurerm_api_management_api.aggregator` (path `""`, `subscription_required = false`, `service_url` = aggregator FQDN via `ingress[0].fqdn`) plus three `azurerm_api_management_api_operation` resources forward the frontend's calls to the aggregator unchanged. `azurerm_api_management_api_policy.aggregator` is an outbound policy that stamps the `X-Served-Via-APIM` response header (demo proof-of-path — the aggregator never sets it; `frontend/server.js` reads it and shows a badge). APIM is Internal-mode, injected into `snet-apim` (needs `azurerm_network_security_group.apim` allowing inbound 3443/6390); its gateway host resolves to the private VIP via the `azure-api.net` private DNS zone. APIM in Developer/Internal mode takes ~30–45 min to provision/update.

**Services:**

| Service | Dir | Port | Node | Key Deps | Exposure |
|---|---|---|---|---|---|
| Frontend | `frontend/` | 80 | 18 (alpine) | express, axios | Private Web App, public access via Application Gateway only |
| Aggregator (Service B) | `aggregator-backend/` | 80 | 20 (alpine) | express, axios, @azure/service-bus, @azure/identity | External-on-internal-CAE (VNet-visible, not public) |
| Backend (Service A) | `backend/` | 80 | 18 (alpine) | express, axios, @azure/service-bus, @azure/identity | Internal (Container App) |

## Key Files

- **`main.tf`** (~850 lines) — The single source of truth for all Azure infrastructure. Covers: resource group, VNet (5 subnets), NAT Gateway, ACR, Container App Environment (internal-LB), 2 Container Apps (Backend A internal, Aggregator VNet-visible), Service Bus (Premium, 1 partition) + private endpoint/DNS, App Service Plan + Frontend Web App, **Application Gateway (WAF_v2) + WAF policy**, and **API Management (Developer_1, Internal VNet mode)** + its `aggregator-api` routing/policy + private DNS.
- **`backend/server.js`** — Fetches weather from MET Norway API (`api.met.no`), subscribes to Service Bus topic, exposes `/api/data` and `/api/event-status`.
- **`aggregator-backend/server.js`** — Publishes events to Service Bus, proxies `/api/event-status` and `/api/aggregated-data` to Backend A, exposes `/api/publish-event`.
- **`frontend/server.js`** — Serves HTML dashboard (weather display + event publishing UI), exposes `/health` (used by the App Gateway probe), proxies API calls to `BACKEND_URL`, and renders a "Routed through APIM" badge from the `x-served-via-apim` response header.

## Working with This Codebase

### Deploying Infrastructure

```bash
terraform init
terraform plan    # uses defaults; .tfvars files are gitignored
terraform apply
```

Deployment triggers Docker build/push automatically via `null_resource.docker_images` (three images: `demo-backend`, `demo-aggregator-backend`, `demo-frontend` pushed to ACR).

### Key Terraform Resources

- `azurerm_container_app.backend` — Backend A, **internal** ingress (`external_enabled = false`; reachable only by other apps inside the CAE — i.e. the aggregator), `workload_profile_name = "Consumption"`
- `azurerm_container_app.aggregator_backend` — Service B, **external** ingress (`external_enabled = true`). Since the CAE is internal-LB, "external" here means VNet-visible (private), **not** public — this is required so APIM (outside the CAE) can reach it (see Networking gotchas), `workload_profile_name = "Consumption"`
- `azurerm_linux_web_app.frontend` — Frontend; VNet-integrated via `snet_webapp`, `public_network_access_enabled = true`, `/health` health check. Locked down with `ip_restriction_default_action = "Deny"` + an `ip_restriction` allowing only `snet_appgateway` (so only the App Gateway can reach it — see Networking gotchas for why public access must stay enabled)
- `azurerm_application_gateway.res-0` — WAF_v2 App Gateway fronting the frontend (public IP `azurerm_public_ip.apgw`, `/health` probe); backend pool = frontend's `default_hostname`
- `azurerm_web_application_firewall_policy.res-0` — OWASP 3.2 ruleset, **Detection** mode
- `azurerm_api_management.apim` — APIM Developer_1, **Internal** VNet mode (`virtual_network_type = "Internal"`, injected into `snet-apim`), system-assigned identity. Routing via `azurerm_api_management_api.aggregator` + 3 operations → aggregator. Requires `azurerm_network_security_group.apim` (inbound 3443/6390) and the `azure-api.net` private DNS zone
- `azurerm_subnet` ×5 — see the subnet list below; `snet-apim` carries the Internal-mode APIM
- `azurerm_servicebus_namespace.main` — Premium namespace, 1 partition (+ private endpoint, private DNS `privatelink.servicebus.windows.net`)
- `azurerm_nat_gateway.nat` — Static egress IP (associated with `snet_cae`) for Backend A's outbound calls to MET Norway

Subnets (all in `10.0.0.0/16`): `snet-pe` (`10.0.0.0/24`, Service Bus PE), `snet-webapp` (`10.0.1.0/24`, Web delegation), `snet-cae` (`10.0.2.0/23`, App env delegation + NAT), `snet-appgateway` (`10.0.4.0/24`), `snet-apim` (`10.0.5.0/24`).

> Resources named `res-0` (App Gateway, WAF policy) look portal-exported; expect verbose/empty-string arguments there.

### Networking gotchas (cost real debugging time — don't relearn these)

- **APIM → Container App requires the aggregator's ingress to be `external_enabled = true`.** A Container App with internal ingress (`external_enabled = false`) is reachable **only from other apps inside the same Container Apps Environment**, not from elsewhere in the VNet. APIM lives in `snet-apim` (outside the CAE), so against an internal-ingress aggregator the CAE returns **HTTP 404 "this Container App does not exist"** (an Envoy/ingress 404, not an APIM or app 404). The CAE is internal-LB, so `external_enabled = true` exposes it on the **private** VNet IP only (not public). Flipping this also drops the `.internal.` label from the FQDN (`<app>.internal.<domain>` → `<app>.<domain>`); the `*` record in the `…azurecontainerapps.io` private DNS zone only matches the single-label external form. Backend A stays internal because only the aggregator (in-CAE) calls it.
- **Frontend `public_network_access_enabled` must be `true`, not `false`.** With it `false`, App Service rejects **all** inbound traffic (only a private endpoint would be allowed — none exists) with **HTTP 403**, so the App Gateway probe fails and the gateway returns **502**. Reachability is instead restricted by the access-restriction rules (`ip_restriction_default_action = "Deny"` + allow `snet_appgateway` over the `Microsoft.Web` service endpoint); those rules only take effect while public access is enabled.
- **Diagnosing from inside the VNet:** internal endpoints (APIM gateway, container FQDNs) aren't resolvable/reachable from a laptop. Run a probe from inside the CAE with `az containerapp exec` (needs a TTY — wrap in `script -q /dev/null …` for non-interactive shells); base64-encode the inline script to survive quote/newline mangling. An APIM-level 404 returns JSON `{"statusCode":404,"message":"Resource not found"}`, whereas a CAE ingress 404 returns the HTML "Container App … does not exist" page — the body tells you which hop failed.

### Key Environment Variables

| Service | Variable | Purpose |
|---|---|---|
| Backend A | `WEATHER_LATITUDE`, `WEATHER_LONGITUDE` | Weather API query coords (default: Hyderabad) |
| Backend A | `SERVICEBUS_NAMESPACE`, `SERVICEBUS_TOPIC_NAME`, `SERVICEBUS_SUBSCRIPTION_NAME` | Service Bus subscription config |
| Aggregator B | `BACKEND_A_URL` | Backend A's internal FQDN |
| Aggregator B | `SERVICEBUS_NAMESPACE`, `SERVICEBUS_TOPIC_NAME` | Service Bus publishing config |
| Frontend | `BACKEND_URL` | APIM gateway URL (`azurerm_api_management.apim.gateway_url`) — routes through APIM, NOT the aggregator FQDN directly |

### Making Changes

- **Application code changes** → Edit `server.js` in the relevant directory. ⚠️ `null_resource.docker_images.triggers` only hashes `backend/server.js` and `frontend/server.js` (plus `app_version`). Its `local-exec` still builds/pushes **all three** images, but **editing only `aggregator-backend/server.js` will NOT re-trigger a rebuild** — bump `var.app_version` or run `terraform taint null_resource.docker_images` to force one.
- ⚠️ **Re-pushed same-tag images aren't auto-pulled.** Images are tagged with `var.app_version` (default `v1`). Rebuilding pushes a new `:v1`, but the Web App / Container Apps pin that tag and won't redeploy on `apply`. To pick up a code change, **restart the Web App / Container App** (or bump `app_version`). APIM/infra-only changes apply normally.
- **Infrastructure changes** → Edit `main.tf`. The naming module (`Azure/naming/azurerm ~> 0.4.0`) generates consistent resource names from `suffix = [workload, environment, region_abbr, instance]`.
- **Add a new service** → Create a directory with `server.js` + `Dockerfile`, add the image build/push to `null_resource.docker_images` (and its `triggers` hash), and add the corresponding `azurerm_container_app` resource.

### Default Variables

- `environment = "dev"`, `workload = "howden"`, `region_abbr = "ins"`, `instance = "01"`, `app_version = "v1"`
- Weather coords default to Hyderabad: `weather_latitude = "17.385"`, `weather_longitude = "78.4867"`

## Important Notes

- **No package.json files** are committed. Dependencies (`express`, `axios`, `@azure/service-bus`, `@azure/identity`) are installed at Docker build time.
- **No tests, linting, or CI/CD** exist. This is a demo/PoC codebase.
- **Exposure chain:** Backend A is internal (reachable only by the Aggregator, in-CAE); the Aggregator is VNet-visible (reachable by APIM); the Frontend is reachable only through the Application Gateway. None of these is publicly reachable except via the App Gateway public IP.
- Both Container Apps use **system-assigned managed identities** for Service Bus auth (no secrets in code): Aggregator = *Data Sender*, Backend = *Data Receiver*. (ACR pull still uses admin user/password.)
- The `null_resource.docker_images` provisioner requires `az` CLI and Docker (building `linux/amd64`) on the machine running `terraform apply`.
