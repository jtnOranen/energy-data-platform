output "storage_account_name" {
  description = "Name of the ADLS Gen2 storage account."
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Resource ID of the ADLS Gen2 storage account."
  value       = azurerm_storage_account.this.id
}

output "landing_container_name" {
  description = "Name of the landing container for raw ingestion data."
  value       = azurerm_storage_container.landing.name
}

output "landing_container_id" {
  description = "Resource Manager ID of the landing container, for container-scoped role assignments."
  value       = azurerm_storage_container.landing.id # a Resource Manager ID, since the container uses storage_account_id
}

output "primary_blob_endpoint" {
  description = "Primary blob endpoint of the ADLS account."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}
