terraform {
  required_version = ">=1.0"

  required_providers {
    azurerm = {
      version = "=2.84.0"
      source  = "hashicorp/azurerm"
    }
    azuread = {
      version = "=2.8.0"
      source  = "hashicorp/azuread"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  use_msi         = var.use_msi_to_authenticate
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  environment     = var.azure_environment
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azuread_client_config" "current" {

}

locals {
  primary_region                = var.regions[0]
  api_base_url                  = "${var.service_name}-api-${var.environment}.${local.functions_baseurl}"
  executing_serviceprincipal_id = data.azuread_client_config.current.object_id
  application_owners            = distinct(concat(var.application_owners, [local.executing_serviceprincipal_id]))
  resource_group_name           = coalesce(var.resource_group_name, "${var.service_name}-${var.environment}")
}

locals {
  function_os_type  = "linux"
  function_version  = "~4"
  function_runtime  = "dotnet-isolated"
  functions_baseurl = var.azure_environment == "usgovernment" ? "azurewebsites.us" : "azurewebsites.net"
}

# Foundation
resource "azurerm_resource_group" "service_resource_group" {
  name     = local.resource_group_name
  location = local.primary_region
}

# Identities
resource "azurerm_user_assigned_identity" "datalake_managed_identity" {
  name                = "${var.service_name}-datalake-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
}

resource "azurerm_user_assigned_identity" "keyvault_api_managed_identity" {
  name                = "${var.service_name}-keyvault-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
}

# Key Vault
resource "azurerm_key_vault" "keyvault" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  sku_name            = "standard"
  tenant_id           = var.tenant_id
}

resource "azurerm_key_vault_access_policy" "executing_owner_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = local.executing_serviceprincipal_id

  secret_permissions = ["Get", "Set", "List", "Delete"]
}

resource "azurerm_key_vault_access_policy" "api_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = azurerm_user_assigned_identity.keyvault_api_managed_identity.principal_id

  secret_permissions = ["Get"]
}

# Storage
resource "azurerm_storage_account" "storage_account" {
  name                     = "${var.service_name}${var.environment}"
  resource_group_name      = azurerm_resource_group.service_resource_group.name
  location                 = azurerm_resource_group.service_resource_group.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

# Logging
resource "azurerm_log_analytics_workspace" "loganalytics" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  sku                 = "PerGB2018"
}

resource "azurerm_application_insights" "appinsights" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  workspace_id        = azurerm_log_analytics_workspace.loganalytics.id
  application_type    = "web"
}

# CosmosDb
resource "azurerm_cosmosdb_account" "cosmosaccount" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  geo_location {
    location          = azurerm_resource_group.service_resource_group.location
    failover_priority = 0
  }

  consistency_policy {
    consistency_level = "Session"
  }

  capabilities {
    name = "EnableServerless"
  }

}

resource "azurerm_key_vault_secret" "cosmos_primary_key" {
  key_vault_id = azurerm_key_vault.keyvault.id
  name         = "cosmos-primary-key"
  value        = azurerm_cosmosdb_account.cosmosaccount.primary_key
}

resource "azurerm_cosmosdb_sql_database" "cosmosdb" {
  name                = var.service_name
  resource_group_name = azurerm_cosmosdb_account.cosmosaccount.resource_group_name
  account_name        = azurerm_cosmosdb_account.cosmosaccount.name

}

resource "azurerm_cosmosdb_sql_container" "cosmoscontainer_clients" {
  name                = "Clients"
  resource_group_name = azurerm_cosmosdb_sql_database.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_sql_database.cosmosdb.account_name
  database_name       = azurerm_cosmosdb_sql_database.cosmosdb.name
  partition_key_path  = "/Area"
}

resource "azurerm_cosmosdb_sql_container" "cosmoscontainer_groups" {
  name                = "Thermostats"
  resource_group_name = azurerm_cosmosdb_sql_database.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_sql_database.cosmosdb.account_name
  database_name       = azurerm_cosmosdb_sql_database.cosmosdb.name
  partition_key_path  = "/Area"
}

# Azure Function
resource "azurerm_app_service_plan" "function_serviceplan" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  kind                = "FunctionApp"
  reserved            = local.function_os_type == "linux" ? true : false # Linux requires a reserved plan
  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

resource "azurerm_function_app" "function_api" {
  name                       = "${var.service_name}-api-${var.environment}"
  resource_group_name        = azurerm_resource_group.service_resource_group.name
  location                   = azurerm_resource_group.service_resource_group.location
  app_service_plan_id        = azurerm_app_service_plan.function_serviceplan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = local.function_version
  https_only                 = true
  os_type                    = local.function_os_type
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.keyvault_api_managed_identity.id]
  }

  site_config {
    http2_enabled   = true
    ftps_state      = "FtpsOnly"
    min_tls_version = "1.2"
  }

  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
    "ASPNETCORE_ENVIRONMENT"                = "Release"
    "FUNCTIONS_EXTENSION_VERSION"           = local.function_version
    "FUNCTIONS_WORKER_RUNTIME"              = local.function_runtime
    "Cosmos_BaseUri"                        = azurerm_cosmosdb_account.cosmosaccount.endpoint
    "KeyVault_BaseUri"                      = azurerm_key_vault.keyvault.vault_uri
    "KeyVault_ManagedIdentityClientId"      = azurerm_user_assigned_identity.keyvault_api_managed_identity.client_id
  }
}

# Worker
resource "azurerm_function_app" "function_worker" {
  name                       = "${var.service_name}-worker-${var.environment}"
  resource_group_name        = azurerm_resource_group.service_resource_group.name
  location                   = azurerm_resource_group.service_resource_group.location
  app_service_plan_id        = azurerm_app_service_plan.function_serviceplan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = local.function_version
  https_only                 = true
  os_type                    = local.function_os_type
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.datalake_managed_identity.id, azurerm_user_assigned_identity.keyvault_api_managed_identity.id]
  }

  site_config {
    http2_enabled   = true
    ftps_state      = "FtpsOnly"
    min_tls_version = "1.2"
  }

  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
    "ASPNETCORE_ENVIRONMENT"                = "Release"
    "FUNCTIONS_EXTENSION_VERSION"           = local.function_version
    "FUNCTIONS_WORKER_RUNTIME"              = local.function_runtime
    "Cosmos_BaseUri"                        = azurerm_cosmosdb_account.cosmosaccount.endpoint
    "KeyVault_BaseUri"                      = azurerm_key_vault.keyvault.vault_uri
    "KeyVault_ManagedIdentityClientId"      = azurerm_user_assigned_identity.keyvault_api_managed_identity.client_id
    "DataLake_BaseUri"                      = "<none>"
    "DataLake_ManagedIdentityClientId"      = azurerm_user_assigned_identity.datalake_api_managed_identity.client_id
    "RuntimeReport_Cron"                    = "0 0 */6 * * *"
  }
}
