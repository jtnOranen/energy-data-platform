provider "azurerm" {
  features {}

  # The storage accounts have Shared Key disabled, so storage data-plane calls use Entra ID.
  storage_use_azuread = true
}

# Reads the same ARM_* environment variables (OIDC in CI) or the az login session locally.
provider "azapi" {}

# Workspace-level provider. In CI, DATABRICKS_AUTH_TYPE=github-oidc-azure makes it exchange the
# GitHub OIDC token for an Entra ID token as the same service principal; locally it uses az login.
provider "databricks" {
  host = "https://${data.azurerm_databricks_workspace.dev.workspace_url}"
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  tags = {
    project    = "energy"
    env        = "dev"
    owner      = var.owner
    managed_by = "terraform"
  }
}

# Created by infra/bootstrap/bootstrap.sh, not Terraform: creating a resource group is a
# subscription-level operation, so having Terraform create it would force the CI service
# principal to hold subscription-wide Contributor, able to touch anything else in this
# (personal) subscription. Keeping it a data source lets the SP's roles stay scoped to
# just this resource group instead. See docs/adr/0004.
data "azurerm_resource_group" "dev" {
  name = "rg-energy-dev"
}

module "storage" {
  source = "../../modules/storage"

  project             = "energy"
  env                 = "dev"
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

module "key_vault" {
  source = "../../modules/key_vault"

  project             = "energy"
  env                 = "dev"
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

module "budget" {
  source = "../../modules/budget"

  project           = "energy"
  env               = "dev"
  resource_group_id = data.azurerm_resource_group.dev.id
  budget_amount_eur = var.budget_amount_eur
  alert_email       = var.alert_email
}

module "function_app" {
  source = "../../modules/function_app"

  project                = "energy"
  env                    = "dev"
  suffix                 = random_string.suffix.result
  location               = var.location
  resource_group_name    = data.azurerm_resource_group.dev.name
  resource_group_id      = data.azurerm_resource_group.dev.id
  tags                   = local.tags
  key_vault_id           = module.key_vault.key_vault_id
  key_vault_uri          = module.key_vault.key_vault_uri
  landing_blob_endpoint  = module.storage.primary_blob_endpoint
  landing_container_name = module.storage.landing_container_name
  landing_container_id   = module.storage.landing_container_id
}

# The owner needs to read/write secrets (API keys) in phase 1. Everyone else gets nothing
# by default -- the vault uses RBAC authorization with no other role assignments.
resource "azurerm_role_assignment" "owner_kv_secrets_officer" {
  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.owner_object_id
}

# The backfill runs locally as the owner and writes to landing (phase 1).
resource "azurerm_role_assignment" "owner_landing" {
  scope                = module.storage.landing_container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.owner_object_id
}

# Created by infra/bootstrap/bootstrap.sh, not Terraform, like the resource group, so the CI service
# principal needs no subscription-level rights. Serverless compute mode. See docs/adr/0012 and 0013.
data "azurerm_databricks_workspace" "dev" {
  name                = "dbw-energy-dev"
  resource_group_name = data.azurerm_resource_group.dev.name
}

module "databricks" {
  source = "../../modules/databricks"

  project              = "energy"
  env                  = "dev"
  location             = var.location
  resource_group_name  = data.azurerm_resource_group.dev.name
  tags                 = local.tags
  storage_account_id   = module.storage.storage_account_id
  landing_container_id = module.storage.landing_container_id
  lake_container_id    = module.storage.lake_container_id
}

module "unity_catalog" {
  source = "../../modules/unity_catalog"

  project                = "energy"
  env                    = "dev"
  access_connector_id    = module.databricks.access_connector_id
  storage_account_name   = module.storage.storage_account_name
  landing_container_name = module.storage.landing_container_name
  lake_container_name    = module.storage.lake_container_name
  owner_user_name        = var.owner
}

module "sql_warehouse" {
  source = "../../modules/sql_warehouse"

  project         = "energy"
  env             = "dev"
  tags            = local.tags
  owner_user_name = var.owner
}
