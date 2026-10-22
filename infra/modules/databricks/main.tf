# The workspace itself is created by bootstrap.sh (ADR 0012); this module adds what Unity Catalog
# needs to reach ADLS: an access connector whose managed identity gets container-scoped roles.
resource "azurerm_databricks_access_connector" "this" {
  name                = "dbac-${var.project}-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Required alongside container-scoped data roles: Unity Catalog hands out user delegation SAS
# tokens, and getting the delegation key is an account-level action. Grants no data access itself.
resource "azurerm_role_assignment" "delegator" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Delegator"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Bronze only reads landing; the function app is the only writer.
resource "azurerm_role_assignment" "landing_reader" {
  scope                = var.landing_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "lake_contributor" {
  scope                = var.lake_container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
