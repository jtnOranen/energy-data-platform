provider "azurerm" {
  features {
    # A destroyed vault stays soft-deleted (7 days), and the apply never tries to recover one. Both
    # purging and recovering act on a subscription-level object (…/locations/<region>/deletedVaults/
    # <name>), outside the CI principal's resource-group scope, so in a rebuild the owner purges it
    # and enters the API keys again (docs/rebuild.md). The Log Analytics workspace keeps its default:
    # soft-deleted on destroy, recovered when one with the same name is created again.
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = false
    }
  }

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

# The suffix of the globally unique names (storage, Key Vault, function app) was a random_string
# until phase 6. A destroy and apply would have drawn a new one and renamed everything, so it is a
# fixed variable now; this block drops the old resource from the state without touching anything.
# Remove the block, and the random provider, once it has been applied.
removed {
  from = random_string.suffix

  lifecycle {
    destroy = false
  }
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
  suffix              = var.suffix
  location            = var.location
  resource_group_name = data.azurerm_resource_group.dev.name
  tags                = local.tags
}

module "key_vault" {
  source = "../../modules/key_vault"

  project             = "energy"
  env                 = "dev"
  suffix              = var.suffix
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
  suffix                 = var.suffix
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

module "monitoring" {
  source = "../../modules/monitoring"

  project                 = "energy"
  env                     = "dev"
  location                = var.location
  resource_group_name     = data.azurerm_resource_group.dev.name
  tags                    = local.tags
  application_insights_id = module.function_app.application_insights_id
  alert_email             = var.alert_email
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

# No personal access tokens: CI, the owner and the jobs all authenticate with Entra ID (OIDC, az
# login, the job's own identity), so a PAT could only be a long-lived secret nobody needs (phase 6).
resource "databricks_workspace_conf" "this" {
  custom_config = {
    enableTokensConfig = "false"
  }
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

  project                 = "energy"
  env                     = "dev"
  access_connector_id     = module.databricks.access_connector_id
  storage_account_name    = module.storage.storage_account_name
  landing_container_name  = module.storage.landing_container_name
  lake_container_name     = module.storage.lake_container_name
  owner_user_name         = var.owner
  pr_service_principal_id = var.pr_client_id
  allow_destroy           = var.allow_destroy
}

module "sql_warehouse" {
  source = "../../modules/sql_warehouse"

  project                 = "energy"
  env                     = "dev"
  tags                    = local.tags
  owner_user_name         = var.owner
  pr_service_principal_id = var.pr_client_id
}
