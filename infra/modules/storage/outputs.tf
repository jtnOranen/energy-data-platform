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
