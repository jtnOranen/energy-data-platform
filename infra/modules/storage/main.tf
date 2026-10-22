resource "azurerm_storage_account" "this" {
  name                = "st${var.project}${var.env}${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true # ADLS Gen2 (hierarchical namespace)
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = var.tags
}

resource "azurerm_storage_container" "landing" {
  name                  = "landing"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Unity Catalog managed storage for the `energy` catalog: managed tables, volumes and Auto Loader
# checkpoints. Separate from `landing` so Databricks can write here while only reading landing.
resource "azurerm_storage_container" "lake" {
  name                  = "lake"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}
