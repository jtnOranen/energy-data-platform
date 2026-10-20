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
  description = "Azure region for the Key Vault."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the Key Vault is created in."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Key Vault."
  type        = map(string)
  default     = {}
}
