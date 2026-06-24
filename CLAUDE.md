# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Big Picture

This is a **single-file Terraform project** (`main.tf`, ~712 lines) that provisions a complete Azure application architecture and deploys three Node.js/Express microservices. There are no `package.json` files committed — dependencies are installed at Docker build time via `npm install` in each Dockerfile. Region is `southindia`.

### Architecture (request path)

```
Internet
    │
    ▼
Application Gateway (WAF_v2, public IP, OWASP 3.2 Detection, /health probe)   ← snet-appgateway
    │
    ▼
Frontend Web App (Linux App Service, :80) — PRIVATE (public_network_access_enabled = false)   ← snet-webapp
    │  serves HTML UI; proxies /api/publish-event, /api/event-status; renders /api/aggregated-data
    ▼
API Management (Developer_1, Internal VNet mode, private VIP)   ← snet-apim
    │  frontend BACKEND_URL = APIM gateway_url (https://<name>.azure-api.net, resolves to private VIP)
    │  "aggregator-api" forwards POST /api/publish-event, GET /api/event-status, GET /api/aggregated-data
    ▼
Aggregator Backend / Service B (Container App, :80, INTERNAL ingress)
    │  publishes events to Service Bus; proxies /api/event-status and /api/aggregated-data to Backend A
    ├──→ Azure Service Bus (topic: demo-events, subscription: demo-processor)  via private endpoint  ← snet-pe
    ▼
Backend / Service A (Container App, :80, INTERNAL ingress)   ← snet-cae
    │  fetches weather from MET Norway API, receives Service Bus messages
    └──→ api.met.no (outbound via NAT Gateway static IP)
```

> **APIM routing:** `azurerm_api_management_api.aggregator` (path `""`, `subscription_required = false`, `service_url` = aggregator internal FQDN) plus three `azurerm_api_management_api_operation` resources forward the frontend's calls to the aggregator unchanged. APIM is Internal-mode, injected into `snet-apim` (needs `azurerm_network_security_group.apim` allowing inbound 3443/6390); its gateway host resolves to the private VIP via the `azure-api.net` private DNS zone. APIM in Developer/Internal mode takes ~30–45 min to provision/update.

**Services:**

| Service | Dir | Port | Node | Key Deps | Exposure |
|---|---|---|---|---|---|
| Frontend | `frontend/` | 80 | 18 (alpine) | express, axios | Private Web App, public access via Application Gateway only |
| Aggregator (Service B) | `aggregator-backend/` | 80 | 20 (alpine) | express, axios, @azure/service-bus, @azure/identity | Internal (Container App) |
| Backend (Service A) | `backend/` | 80 | 18 (alpine) | express, axios, @azure/service-bus, @azure/identity | Internal (Container App) |

## Key Files

- **`main.tf`** (~712 lines) — The single source of truth for all Azure infrastructure. Covers: resource group, VNet (5 subnets), NAT Gateway, ACR, Container App Environment, 2 (internal) Container Apps, Service Bus (Premium, 1 partition) + private endpoint/DNS, App Service Plan + Frontend Web App, **Application Gateway (WAF_v2) + WAF policy**, and **API Management (Developer_1, Internal VNet mode)** + its `aggregator-api` routing + private DNS.
- **`backend/server.js`** — Fetches weather from MET Norway API (`api.met.no`), subscribes to Service Bus topic, exposes `/api/data` and `/api/event-status`.
- **`aggregator-backend/server.js`** — Publishes events to Service Bus, proxies `/api/event-status` and `/api/aggregated-data` to Backend A, exposes `/api/publish-event`.
- **`frontend/server.js`** — Serves HTML dashboard (weather display + event publishing UI), exposes `/health` (used by the App Gateway probe), proxies API calls to `BACKEND_URL`.

## Working with This Codebase

### Deploying Infrastructure

```bash
terraform init
terraform plan    # uses defaults; .tfvars files are gitignored
terraform apply
```

Deployment triggers Docker build/push automatically via `null_resource.docker_images` (three images: `demo-backend`, `demo-aggregator-backend`, `demo-frontend` pushed to ACR).

### Key Terraform Resources

- `azurerm_container_app.backend` — Backend A, **internal** ingress (resolvable only from within the VNet)
- `azurerm_container_app.aggregator_backend` — Service B, **internal** ingress (`external_enabled = false`)
- `azurerm_linux_web_app.frontend` — Frontend; VNet-integrated via `snet_webapp`, `public_network_access_enabled = false`, `/health` health check
- `azurerm_application_gateway.res-0` — WAF_v2 App Gateway fronting the frontend (public IP `azurerm_public_ip.apgw`, `/health` probe); backend pool = frontend's `default_hostname`
- `azurerm_web_application_firewall_policy.res-0` — OWASP 3.2 ruleset, **Detection** mode
- `azurerm_api_management.apim` — APIM Developer_1, **Internal** VNet mode (`virtual_network_type = "Internal"`, injected into `snet-apim`), system-assigned identity. Routing via `azurerm_api_management_api.aggregator` + 3 operations → aggregator. Requires `azurerm_network_security_group.apim` (inbound 3443/6390) and the `azure-api.net` private DNS zone
- `azurerm_subnet` ×5 — see the subnet list below; `snet-apim` carries the Internal-mode APIM
- `azurerm_servicebus_namespace.main` — Premium namespace, 1 partition (+ private endpoint, private DNS `privatelink.servicebus.windows.net`)
- `azurerm_nat_gateway.nat` — Static egress IP (associated with `snet_cae`) for Backend A's outbound calls to MET Norway

Subnets (all in `10.0.0.0/16`): `snet-pe` (`10.0.0.0/24`, Service Bus PE), `snet-webapp` (`10.0.1.0/24`, Web delegation), `snet-cae` (`10.0.2.0/23`, App env delegation + NAT), `snet-appgateway` (`10.0.4.0/24`), `snet-apim` (`10.0.5.0/24`).

> Resources named `res-0` (App Gateway, WAF policy) look portal-exported; expect verbose/empty-string arguments there.

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
- **Infrastructure changes** → Edit `main.tf`. The naming module (`Azure/naming/azurerm ~> 0.4.0`) generates consistent resource names from `suffix = [workload, environment, region_abbr, instance]`.
- **Add a new service** → Create a directory with `server.js` + `Dockerfile`, add the image build/push to `null_resource.docker_images` (and its `triggers` hash), and add the corresponding `azurerm_container_app` resource.

### Default Variables

- `environment = "dev"`, `workload = "howden"`, `region_abbr = "ins"`, `instance = "01"`, `app_version = "v1"`
- Weather coords default to Hyderabad: `weather_latitude = "17.385"`, `weather_longitude = "78.4867"`

## Important Notes

- **No package.json files** are committed. Dependencies (`express`, `axios`, `@azure/service-bus`, `@azure/identity`) are installed at Docker build time.
- **No tests, linting, or CI/CD** exist. This is a demo/PoC codebase.
- **Both Container Apps are internal-only.** Backend A is reachable only via the Aggregator; the Aggregator is reachable only via APIM. The Frontend Web App has public access disabled and is reachable only through the Application Gateway.
- Both Container Apps use **system-assigned managed identities** for Service Bus auth (no secrets in code): Aggregator = *Data Sender*, Backend = *Data Receiver*. (ACR pull still uses admin user/password.)
- The `null_resource.docker_images` provisioner requires `az` CLI and Docker (building `linux/amd64`) on the machine running `terraform apply`.
