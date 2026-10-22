terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    azapi = {
      source = "azure/azapi"
    }
  }
}

# --- Monitoring -------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.project}-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  # Cost guard: the function logs a few KB per run. Ingestion stops for the day at the cap.
  daily_quota_gb = 0.1
  tags           = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.project}-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  # Telemetry must be sent with an Entra token (the function's identity), so the
  # instrumentation key in the connection string can't be used to ingest anything.
  local_authentication_enabled = false
  tags                         = var.tags
}

# --- Host and deployment storage ---------------------------------------------------------

# Separate from the ADLS landing account: Functions host storage shouldn't have a
# hierarchical namespace, and keeping runtime state apart from data keeps roles narrow.
resource "azurerm_storage_account" "host" {
  name                            = "st${var.project}fn${var.env}${var.suffix}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # Host and deployment storage are identity-based (see the function app below), so no client needs
  # the account keys; with Shared Key off they're useless even though azurerm keeps them in state.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  tags                            = var.tags
}

resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.host.id
  container_access_type = "private"
}

# --- Function app ---------------------------------------------------------------------------

resource "azurerm_service_plan" "this" {
  name                = "asp-${var.project}-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = var.tags
}

locals {
  key_vault_secret_uri = "${trimsuffix(var.key_vault_uri, "/")}/secrets"

  app_settings = {
    # Identity-based host storage: no account key anywhere.
    AzureWebJobsStorage__accountName = azurerm_storage_account.host.name
    AzureWebJobsStorage__credential  = "managedidentity"

    # With local authentication disabled on App Insights this string is not a credential,
    # so it doesn't need to be treated as sensitive (that would hide the whole plan diff).
    APPLICATIONINSIGHTS_CONNECTION_STRING     = nonsensitive(azurerm_application_insights.this.connection_string)
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD"

    # Key Vault references, resolved by the function's identity. The values never pass
    # through Terraform. Versionless URIs always pick up the latest secret version.
    FINGRID_API_KEY = "@Microsoft.KeyVault(SecretUri=${local.key_vault_secret_uri}/fingrid-api-key/)"
    ENTSOE_TOKEN    = "@Microsoft.KeyVault(SecretUri=${local.key_vault_secret_uri}/entsoe-token/)"

    LANDING_BLOB_ENDPOINT = var.landing_blob_endpoint
    LANDING_CONTAINER     = var.landing_container_name
  }
}

# azapi instead of azurerm_function_app_flex_consumption: azurerm 4.81 always injects an
# AzureWebJobsStorage connection string with an empty key, which either breaks identity-based
# host storage or never converges (hashicorp/terraform-provider-azurerm#33211). See ADR 0010.
resource "azapi_resource" "function_app" {
  type      = "Microsoft.Web/sites@2024-11-01"
  name      = "func-${var.project}-ingest-${var.env}-${var.suffix}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  # Azure returns serverFarmId as ".../serverfarms/..." while azurerm gives ".../serverFarms/...".
  # ARM IDs are case-insensitive, so ignore casing instead of showing a permanent diff.
  ignore_casing = true

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "functionapp,linux"
    properties = {
      serverFarmId = azurerm_service_plan.this.id
      httpsOnly    = true
      siteConfig = {
        minTlsVersion = "1.2"
        appSettings   = [for name, value in local.app_settings : { name = name, value = value }]
      }
      functionAppConfig = {
        deployment = {
          storage = {
            type  = "blobContainer"
            value = "${azurerm_storage_account.host.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
            authentication = {
              type = "SystemAssignedIdentity"
            }
          }
        }
        runtime = {
          name    = "python"
          version = var.python_version
        }
        scaleAndConcurrency = {
          # Three hourly timers need one instance; the cap is a cost guard, not a target.
          maximumInstanceCount = 40
          instanceMemoryMB     = 2048
        }
      }
    }
  }

  # Azure adds this tag itself to link the app to Application Insights in the portal. Removing it
  # on every apply would only make Azure add it back, so leave it alone.
  lifecycle {
    ignore_changes = [tags["hidden-link: /app-insights-resource-id"]]
  }
}

# --- Role assignments for the function's identity -----------------------------------------
# principal_type skips the directory lookup, which can fail for a few seconds after a new
# identity is created.

resource "azurerm_role_assignment" "host_storage" {
  scope                = azurerm_storage_account.host.id
  role_definition_name = "Storage Blob Data Owner" # host storage + deployment package
  principal_id         = azapi_resource.function_app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "app_insights" {
  scope                = azurerm_application_insights.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azapi_resource.function_app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "key_vault" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azapi_resource.function_app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "landing" {
  scope                = var.landing_container_id # the container, not the whole account
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azapi_resource.function_app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
