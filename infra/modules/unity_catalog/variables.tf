variable "project" {
  description = "Project short name; also the catalog name."
  type        = string
}

variable "env" {
  description = "Environment short name (e.g. dev), used in naming."
  type        = string
}

variable "access_connector_id" {
  description = "Resource ID of the Databricks access connector used by the storage credential."
  type        = string
}

variable "storage_account_name" {
  description = "Name of the ADLS Gen2 account holding the landing and lake containers."
  type        = string
}

variable "landing_container_name" {
  description = "Container with the raw ingestion files (read-only external location)."
  type        = string
}

variable "lake_container_name" {
  description = "Container for Unity Catalog managed storage."
  type        = string
}

variable "pr_service_principal_id" {
  description = "Application ID of the read-only service principal pull requests run as (ADR 0016)."
  type        = string
}

variable "owner_user_name" {
  description = "Owner's Databricks user name (their Entra ID user principal name), granted read access and CREATE SCHEMA for dbt dev schemas."
  type        = string
}
