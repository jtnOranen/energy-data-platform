variable "project" {
  description = "Project short name, used in resource naming."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in resource naming."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the resource group the budget applies to."
  type        = string
}

variable "budget_amount_eur" {
  description = "Monthly budget amount in EUR."
  type        = number
}

variable "alert_email" {
  description = "Email address notified when a budget threshold is crossed."
  type        = string
  sensitive   = true
}
