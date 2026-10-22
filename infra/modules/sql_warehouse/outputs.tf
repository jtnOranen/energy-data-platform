output "warehouse_id" {
  description = "ID of the SQL warehouse, for the dbt task in the bundle."
  value       = databricks_sql_endpoint.this.id
}

output "http_path" {
  description = "HTTP path of the SQL warehouse, for dbt profiles."
  value       = databricks_sql_endpoint.this.odbc_params[0].path
}
