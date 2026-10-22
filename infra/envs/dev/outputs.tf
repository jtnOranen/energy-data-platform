output "resource_group_name" {
  description = "Name of the dev resource group."
  value       = data.azurerm_resource_group.dev.name
}

output "storage_account_name" {
  description = "Name of the ADLS Gen2 landing storage account."
  value       = module.storage.storage_account_name
}

output "key_vault_name" {
  description = "Name of the dev Key Vault."
  value       = module.key_vault.key_vault_name
}

output "function_app_name" {
  description = "Name of the ingestion function app."
  value       = module.function_app.function_app_name
}

output "databricks_workspace_url" {
  description = "URL of the Databricks workspace (created by bootstrap.sh)."
  value       = "https://${data.azurerm_databricks_workspace.dev.workspace_url}"
}

output "databricks_access_connector_id" {
  description = "Resource ID of the Databricks access connector."
  value       = module.databricks.access_connector_id
}

output "databricks_catalog_name" {
  description = "Name of the Unity Catalog catalog."
  value       = module.unity_catalog.catalog_name
}

output "databricks_checkpoints_volume_path" {
  description = "Volume path for Auto Loader checkpoints."
  value       = module.unity_catalog.checkpoints_volume_path
}
