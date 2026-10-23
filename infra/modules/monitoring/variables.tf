variable "project" {
  description = "Project short name, used in naming."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in naming."
  type        = string
}

variable "location" {
  description = "Azure region for the alert rule (same as Application Insights)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the action group and alert rule are created in."
  type        = string
}

variable "tags" {
  description = "Tags applied to the action group and the alert rule."
  type        = map(string)
  default     = {}
}

variable "application_insights_id" {
  description = "Resource ID of the Application Insights the ingestion functions log to."
  type        = string
}

variable "alert_email" {
  description = "Email address the action group notifies."
  type        = string
  sensitive   = true # repo is public; keep it out of plan output and PR comments
}
