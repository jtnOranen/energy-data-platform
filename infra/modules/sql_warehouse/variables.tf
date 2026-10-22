variable "project" {
  description = "Project short name, used in naming."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in naming."
  type        = string
}

variable "tags" {
  description = "Tags applied to the warehouse (Databricks passes them to its usage records)."
  type        = map(string)
  default     = {}
}

variable "owner_user_name" {
  description = "Owner's Databricks user name (their Entra ID user principal name), granted CAN_USE."
  type        = string
}
