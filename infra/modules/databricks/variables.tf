variable "project" {
  description = "Project short name, used in resource naming."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in resource naming."
  type        = string
}

variable "location" {
  description = "Azure region for the access connector (same as the storage account)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the access connector is created in."
  type        = string
}

variable "tags" {
  description = "Tags applied to the access connector."
  type        = map(string)
  default     = {}
}

variable "storage_account_id" {
  description = "Resource ID of the ADLS account, for the Storage Blob Delegator role."
  type        = string
}

variable "landing_container_id" {
  description = "Resource Manager ID of the landing container (read-only access)."
  type        = string
}

variable "lake_container_id" {
  description = "Resource Manager ID of the lake container (read/write access)."
  type        = string
}
