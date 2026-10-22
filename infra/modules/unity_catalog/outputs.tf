output "catalog_name" {
  description = "Name of the Unity Catalog catalog."
  value       = databricks_catalog.this.name
}

output "silver_schema_name" {
  description = "Name of the silver schema (dbt staging and intermediate)."
  value       = databricks_schema.silver.name
}

output "gold_schema_name" {
  description = "Name of the gold schema (dbt star schema)."
  value       = databricks_schema.gold.name
}

output "checkpoints_volume_path" {
  description = "Path of the Auto Loader checkpoints volume."
  value       = "/Volumes/${databricks_volume.checkpoints.catalog_name}/${databricks_volume.checkpoints.schema_name}/${databricks_volume.checkpoints.name}"
}
