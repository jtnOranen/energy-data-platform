output "access_connector_id" {
  description = "Resource ID of the access connector, for the Unity Catalog storage credential."
  value       = azurerm_databricks_access_connector.this.id
}

output "access_connector_principal_id" {
  description = "Object ID of the access connector's system-assigned identity."
  value       = azurerm_databricks_access_connector.this.identity[0].principal_id
}
