data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                = "kv-${var.project}-${var.env}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name = "standard"

  # RBAC authorization only -- no access policies. Who gets which role is decided by the
  # caller (see envs/dev/main.tf), so this module stays reusable across environments.
  rbac_authorization_enabled = true

  # Dev environment: short soft-delete window, no purge protection, so the name can be
  # freed immediately if the vault needs recreating. Revisit before a prod environment
  # exists.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = var.tags
}
