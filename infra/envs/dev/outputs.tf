output "resource_group_name" {
  description = "Name of the dev resource group."
  value       = azurerm_resource_group.dev.name
}

output "storage_account_name" {
  description = "Name of the ADLS Gen2 landing storage account."
  value       = module.storage.storage_account_name
}

output "key_vault_name" {
  description = "Name of the dev Key Vault."
  value       = module.key_vault.key_vault_name
}
