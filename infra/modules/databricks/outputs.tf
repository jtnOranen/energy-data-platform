output "access_connector_id" {
  description = "Resource ID of the access connector, for the Unity Catalog storage credential."
  value       = azurerm_databricks_access_connector.this.id

  # The storage credential can only be registered once the connector holds Reader on itself.
  depends_on = [azurerm_role_assignment.self_reader]
}

output "access_connector_principal_id" {
  description = "Object ID of the access connector's system-assigned identity."
  value       = azurerm_databricks_access_connector.this.identity[0].principal_id
}
