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