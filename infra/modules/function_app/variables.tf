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
  description = "Azure region for all resources in this module."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group the resources are created in."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the same resource group (parent of the azapi function app)."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "python_version" {
  description = "Python runtime version for the function app (see docs/phases/phase-1-ingestion.md)."
  type        = string
  default     = "3.13"
}

variable "key_vault_id" {
  description = "Resource ID of the Key Vault holding the API keys."
  type        = string
}

variable "key_vault_uri" {
  description = "URI of the same Key Vault, used to build Key Vault references in app settings."
  type        = string
}

variable "landing_blob_endpoint" {
  description = "Primary blob endpoint of the ADLS account the function writes raw files to."
  type        = string
}

variable "landing_container_name" {
  description = "Name of the landing container."
  type        = string
}

variable "landing_container_id" {
  description = "Resource Manager ID of the landing container (role assignment scope)."
  type        = string
}
