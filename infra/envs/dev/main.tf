provider "azurerm" {
  features {}
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

resource "azurerm_resource_group" "dev" {
  name     = "rg-energy-dev"
  location = var.location
  tags     = local.tags
}

module "storage" {
  source = "../../modules/storage"

  project             = "energy"
  env                 = "dev"
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.dev.name
  tags                = local.tags
}

module "key_vault" {
  source = "../../modules/key_vault"

  project             = "energy"
  env                 = "dev"
  suffix              = random_string.suffix.result
  location            = var.location
  resource_group_name = azurerm_resource_group.dev.name
  tags                = local.tags
}

module "budget" {
  source = "../../modules/budget"

  project           = "energy"
  env               = "dev"
  resource_group_id = azurerm_resource_group.dev.id
  budget_amount_eur = var.budget_amount_eur
  alert_email       = var.alert_email
}

# The owner needs to read/write secrets (API keys) in phase 1. Everyone else gets nothing
# by default -- the vault uses RBAC authorization with no other role assignments.
resource "azurerm_role_assignment" "owner_kv_secrets_officer" {
  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.owner_object_id
}
