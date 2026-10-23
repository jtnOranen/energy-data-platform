output "action_group_id" {
  description = "Resource ID of the action group that emails the owner."
  value       = azurerm_monitor_action_group.this.id
}
