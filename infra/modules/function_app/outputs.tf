output "function_app_name" {
  description = "Name of the function app (deploy target for CI)."
  value       = azapi_resource.function_app.name
}

output "function_app_principal_id" {
  description = "Object ID of the function app's system-assigned identity."
  value       = azapi_resource.function_app.identity[0].principal_id
}

output "application_insights_name" {
  description = "Name of the Application Insights resource the function logs to."
  value       = azurerm_application_insights.this.name
}

output "application_insights_id" {
  description = "Resource ID of the Application Insights resource (scope for failure alerts)."
  value       = azurerm_application_insights.this.id
}
