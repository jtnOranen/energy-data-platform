variable "project" {
  description = "Project short name, used in resource naming."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in resource naming."
  type        = string
}

variable "suffix" {
  description = "Random suffix appended to globally-unique resource names."
  type        = string
}

variable "location" {
  description = "Azure region for the storage account."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the storage account is created in."
  type        = string
}

variable "tags" {
  description = "Tags applied to the storage account."
  type        = map(string)
  default     = {}
}
