terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# --- Variables ---
variable "environment" {
  type    = string
  default = "dev"
}

variable "workload" {
  type    = string
  default = "howden"
}

variable "region_abbr" {
  type    = string
  default = "ins"
}

variable "instance" {
  type    = string
  default = "01"
}

variable "app_version" {
  type        = string
  default     = "v1"
  description = "The image tag used for both the frontend and backend Docker containers"
}

variable "weather_latitude" {
  type        = string
  default     = "17.385"
  description = "Latitude the backend uses to query the public weather API (default: Hyderabad)"
}

variable "weather_longitude" {
  type        = string
  default     = "78.4867"
  description = "Longitude the backend uses to query the public weather API (default: Hyderabad)"
}


# --- Official Azure Naming Module ---
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4.0"
  suffix  = [var.workload, var.environment, var.region_abbr, var.instance]
}

# --- Resource Group ---
resource "azurerm_resource_group" "main" {
  name     = module.naming.resource_group.name
  location = "southindia"
}

# --- Virtual Network & Subnets ---
resource "azurerm_virtual_network" "vnet" {
  name                = module.naming.virtual_network.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "snet_webapp" {
  name                 = "snet-webapp"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "webapp-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "snet_cae" {
  name                 = "snet-cae"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/23"]

  delegation {
    name = "cae-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "snet_apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.5.0/24"]
}

resource "azurerm_subnet" "snet_appgateway" {
  name                 = "snet-appgateway"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/24"]
}

# --- Private Subnet for Service Bus Private Endpoint ---
resource "azurerm_subnet" "snet_private_endpoint" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

# --- NAT Gateway (deterministic outbound egress for the backend) ---
# Associated with snet_cae so the Container App backend's outbound traffic
# (to the public weather API) leaves the VNet through a single static IP.
resource "azurerm_public_ip" "nat" {
  name                = module.naming.public_ip.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "nat" {
  name                = module.naming.nat_gateway.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "cae" {
  subnet_id      = azurerm_subnet.snet_cae.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

# --- Azure Container Registry ---
resource "azurerm_container_registry" "acr" {
  name                = module.naming.container_registry.name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
}

# --- Build and push Docker images to ACR ---
resource "null_resource" "docker_images" {
  triggers = {
    version_tag        = var.app_version
    backend_code_hash  = filemd5("${path.root}/backend/server.js")
    frontend_code_hash = filemd5("${path.root}/frontend/server.js")
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -e

      # Login to ACR
      az acr login --name ${azurerm_container_registry.acr.name} --resource-group ${azurerm_resource_group.main.name}

      # Build and push backend image
      docker build --platform=linux/amd64 -t ${azurerm_container_registry.acr.login_server}/demo-backend:${var.app_version} ./backend
      docker push ${azurerm_container_registry.acr.login_server}/demo-backend:${var.app_version}

      # Build and push aggregator backend image
      docker build --platform=linux/amd64 -t ${azurerm_container_registry.acr.login_server}/demo-aggregator-backend:${var.app_version} ./aggregator-backend
      docker push ${azurerm_container_registry.acr.login_server}/demo-aggregator-backend:${var.app_version}

      # Build and push frontend image
      docker build --platform=linux/amd64 -t ${azurerm_container_registry.acr.login_server}/demo-frontend:${var.app_version} ./frontend
      docker push ${azurerm_container_registry.acr.login_server}/demo-frontend:${var.app_version}
    EOT
    working_dir = path.root
  }

  depends_on = [azurerm_container_registry.acr]
}

resource "random_string" "frontend_suffix" {
  length  = 5
  lower   = true
  upper   = false
  special = false
}

# --- Container App Environment (Private) ---
resource "azurerm_container_app_environment" "cae" {
  name                = module.naming.container_app_environment.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Lock it inside the Virtual Network
  infrastructure_subnet_id       = azurerm_subnet.snet_cae.id
  internal_load_balancer_enabled = true

  # NAT Gateway egress requires a workload profiles environment (not Consumption-only).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  depends_on = [azurerm_subnet_nat_gateway_association.cae]
}

# --- Private DNS Zone for CAE ---
resource "azurerm_private_dns_zone" "cae_zone" {
  name                = azurerm_container_app_environment.cae.default_domain
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "vnet_link" {
  name                  = "cae-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cae_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_a_record" "cae_record" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae_zone.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.cae.static_ip_address]
}

# --- Container App (Backend) ---
resource "azurerm_container_app" "backend" {
  name                         = module.naming.container_app.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  # Crucial: Wait for the images to be pushed before deploying
  depends_on = [null_resource.docker_images]

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  template {
    container {
      name   = "demo-backend"
      image  = "${azurerm_container_registry.acr.login_server}/demo-backend:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"
      env {
        name  = "WEATHER_LATITUDE"
        value = var.weather_latitude
      }
      env {
        name  = "WEATHER_LONGITUDE"
        value = var.weather_longitude
      }
      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = azurerm_servicebus_namespace.main.name
      }
      env {
        name  = "SERVICEBUS_TOPIC_NAME"
        value = azurerm_servicebus_topic.demo_events.name
      }
      env {
        name  = "SERVICEBUS_SUBSCRIPTION_NAME"
        value = azurerm_servicebus_subscription.demo_processor.name
      }
    }

    min_replicas = 1
    max_replicas = 1
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = false
    target_port                = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Container App (Aggregator Backend / Service B) ---
resource "azurerm_container_app" "aggregator_backend" {
  name                         = "${module.naming.container_app.name}-aggregator"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  depends_on = [null_resource.docker_images]

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  template {
    container {
      name   = "demo-aggregator-backend"
      image  = "${azurerm_container_registry.acr.login_server}/demo-aggregator-backend:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "BACKEND_A_URL"
        value = "https://${azurerm_container_app.backend.ingress[0].fqdn}"
      }
      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = azurerm_servicebus_namespace.main.name
      }
      env {
        name  = "SERVICEBUS_TOPIC_NAME"
        value = azurerm_servicebus_topic.demo_events.name
      }
    }
    min_replicas = 1
    max_replicas = 1
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Service Bus Namespace ---
resource "azurerm_servicebus_namespace" "main" {
  name                         = module.naming.servicebus_namespace.name
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1
}

# --- Service Bus Topic ---
resource "azurerm_servicebus_topic" "demo_events" {
  name         = module.naming.servicebus_topic.name
  namespace_id = azurerm_servicebus_namespace.main.id
}

# --- Service Bus Subscription ---
resource "azurerm_servicebus_subscription" "demo_processor" {
  name               = "${module.naming.servicebus_topic.name}-subscription"
  topic_id           = azurerm_servicebus_topic.demo_events.id
  max_delivery_count = 10
}

# --- Service Bus Private Endpoint ---
resource "azurerm_private_endpoint" "servicebus" {
  name                = "${module.naming.private_endpoint.name}-sb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-sb"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }
}

# --- Private DNS Zone for Service Bus ---
resource "azurerm_private_dns_zone" "servicebus" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

# --- Link Private DNS Zone to VNet ---
resource "azurerm_private_dns_zone_virtual_network_link" "servicebus_vnet_link" {
  name                  = "servicebus-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

# --- Private DNS A Record for Service Bus ---
resource "azurerm_private_dns_a_record" "servicebus" {
  name                = azurerm_servicebus_namespace.main.name
  zone_name           = azurerm_private_dns_zone.servicebus.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address]
}

# --- Role Assignment: Aggregator Backend - Service Bus Data Sender ---
resource "azurerm_role_assignment" "aggregator_backend_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_container_app.aggregator_backend.identity[0].principal_id
}

# --- Role Assignment: Backend - Service Bus Data Receiver ---
resource "azurerm_role_assignment" "backend_receiver" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_container_app.backend.identity[0].principal_id
}

# --- App Service Plan ---
resource "azurerm_service_plan" "asp" {
  name                = module.naming.app_service_plan.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "B1"
}

# --- Web App (Frontend) ---
resource "azurerm_linux_web_app" "frontend" {
  name                = "${module.naming.app_service.name}-${random_string.frontend_suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.asp.id

  # Connect to the VNet Subnet
  virtual_network_subnet_id = azurerm_subnet.snet_webapp.id

  # Crucial: Wait for the images to be pushed before deploying
  depends_on = [null_resource.docker_images]

  site_config {
    # Force traffic to use Private DNS for resolution
    vnet_route_all_enabled = true

    # --- HEALTH PROBE CONFIGURATION ---
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    # ----------------------------------

    application_stack {
      docker_image_name        = "demo-frontend:${var.app_version}"
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = {
    "BACKEND_URL"                         = "https://${azurerm_container_app.aggregator_backend.ingress[0].fqdn}"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  }
}

resource "azurerm_web_application_firewall_policy" "res-0" {
  location            = azurerm_resource_group.main.location
  name                = module.naming.web_application_firewall_policy.name
  resource_group_name = azurerm_resource_group.main.name
  tags                = {}
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
  policy_settings {
    enabled                          = true
    file_upload_limit_in_mb          = 100
    max_request_body_size_in_kb      = 128
    mode                             = "Detection"
    request_body_check               = true
    request_body_inspect_limit_in_kb = 128
  }
}

resource "azurerm_public_ip" "apgw" {
  name                = "${module.naming.public_ip.name}-02"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}


resource "azurerm_application_gateway" "res-0" {
  enable_http2       = true
  fips_enabled       = false
  firewall_policy_id = azurerm_web_application_firewall_policy.res-0.id
  # firewall_policy_id                = "/subscriptions/bf64dbbf-7dac-472e-92ca-6ee6c08d1055/resourceGroups/rg-howden-dev-ins-01/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/wafhowdendevins01"
  force_firewall_policy_association = false
  location                          = azurerm_resource_group.main.location
  name                              = module.naming.application_gateway.name
  resource_group_name               = azurerm_resource_group.main.name
  tags                              = {}
  zones                             = []
  backend_address_pool {
    fqdns        = [azurerm_linux_web_app.frontend.default_hostname] #TODO Will check tomorrow
    ip_addresses = []
    name         = "backend-pool-webapp-${var.instance}"
  }
  backend_http_settings {
    cookie_based_affinity                = "Disabled"
    name                                 = "backend-settings-${var.instance}"
    pick_host_name_from_backend_address  = true
    port                                 = 80
    probe_name                           = "healthprobe${var.instance}"
    protocol                             = "Http"
    request_timeout                      = 20
    trusted_root_certificate_names       = []
  }
  frontend_ip_configuration {
    name                            = "appGwPublicFrontendIpIPv4"
    private_ip_address              = ""
    private_ip_address_allocation   = "Dynamic"
    private_link_configuration_name = ""
    public_ip_address_id            = azurerm_public_ip.apgw.id
    # public_ip_address_id            = "/subscriptions/bf64dbbf-7dac-472e-92ca-6ee6c08d1055/resourceGroups/rg-howden-dev-ins-01/providers/Microsoft.Network/publicIPAddresses/pip-howden-dev-ins-02"
    subnet_id = ""
  }
  frontend_port {
    name = "port_80"
    port = 80
  }
  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.snet_appgateway.id
    # subnet_id = "/subscriptions/bf64dbbf-7dac-472e-92ca-6ee6c08d1055/resourceGroups/rg-howden-dev-ins-01/providers/Microsoft.Network/virtualNetworks/vnet-howden-dev-ins-01/subnets/snet-appgateway"
  }
  http_listener {
    frontend_ip_configuration_name = "appGwPublicFrontendIpIPv4"
    frontend_port_name             = "port_80"
    name                           = "Listener${var.instance}"
    protocol                       = "Http"
    require_sni                    = false
  }
  probe {
    interval                                  = 30
    minimum_servers                           = 0
    name                                      = "healthprobe${var.instance}"
    path                                      = "/health"
    pick_host_name_from_backend_http_settings = true
    protocol                                  = "Http"
    timeout                                   = 30
    unhealthy_threshold                       = 3
    match {
      status_code = ["200-399"]
    }
  }
  request_routing_rule {
    backend_address_pool_name   = "backend-pool-webapp-${var.instance}"
    backend_http_settings_name  = "backend-settings-${var.instance}"
    http_listener_name          = "Listener${var.instance}"
    name                        = "Rule${var.instance}"
    priority                    = 1
    rule_type                   = "Basic"
  }
  sku {
    capacity = 1
    name     = "WAF_v2"
    tier     = "WAF_v2"
  }
}

# --- Outputs ---
output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "frontend_url" {
  value = "http://${azurerm_linux_web_app.frontend.default_hostname}"
}

output "aggregator_backend_url" {
  value       = "http://${azurerm_container_app.aggregator_backend.ingress[0].fqdn}"
  description = "Service B endpoint for frontend requests."
}

output "backend_url" {
  value       = "http://${azurerm_container_app.backend.ingress[0].fqdn}"
  description = "Note: This existing backend is internal-only and will only resolve from within the private network."
}

output "nat_egress_ip" {
  value       = azurerm_public_ip.nat.ip_address
  description = "Static public IP the backend uses to reach the public weather API via the NAT Gateway."
}

output "servicebus_namespace_name" {
  value       = azurerm_servicebus_namespace.main.name
  description = "Service Bus namespace name for use with managed identity authentication."
}

output "servicebus_namespace_id" {
  value       = azurerm_servicebus_namespace.main.id
  description = "Service Bus namespace resource ID."
}

output "servicebus_private_endpoint_ip" {
  value       = azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address
  description = "Private IP address of the Service Bus private endpoint."
}

output "private_dns_zone_id" {
  value       = azurerm_private_dns_zone.servicebus.id
  description = "Private DNS zone ID for Service Bus (privatelink.servicebus.windows.net)."
}