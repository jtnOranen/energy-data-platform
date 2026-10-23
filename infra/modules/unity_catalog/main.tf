terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

# Unity Catalog objects for the platform. The CI service principal creates and therefore owns them;
# it can, because workspace admins of an auto-enabled workspace hold CREATE STORAGE CREDENTIAL,
# CREATE EXTERNAL LOCATION and CREATE CATALOG on the metastore (phase 2 spec, step 0).

resource "databricks_storage_credential" "adls" {
  name    = "${var.project}-${var.env}-adls"
  comment = "Access connector identity for the ${var.project} ADLS account. Managed by Terraform."

  azure_managed_identity {
    access_connector_id = var.access_connector_id
  }
}

# Read-only: the function app is the only writer to landing. The access connector only has
# Storage Blob Data Reader on this container.
resource "databricks_external_location" "landing" {
  name            = "landing"
  url             = "abfss://${var.landing_container_name}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.adls.name
  read_only       = true
  comment         = "Raw API responses written by the ingestion function. Managed by Terraform."
}

resource "databricks_external_location" "lake" {
  name            = "lake"
  url             = "abfss://${var.lake_container_name}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.adls.name
  comment         = "Managed storage for the ${var.project} catalog. Managed by Terraform."
}

# storage_root keeps the catalog's managed tables in our own container rather than wherever the
# auto-provisioned metastore would put them.
resource "databricks_catalog" "this" {
  name         = var.project
  storage_root = "${databricks_external_location.lake.url}${var.project}"
  comment      = "Energy data platform: bronze, silver and gold. Managed by Terraform."
}

resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.this.name
  name         = "bronze"
  comment      = "Raw records loaded from landing by Auto Loader, one table per source dataset."
}

# dbt writes staging and intermediate models, seeds and the snapshot to silver, the star schema to
# gold. Terraform creates them, like bronze, so the CI SP owns every schema and all grants live here;
# dbt creates only the owner's dev schemas and, in phase 4, the PR schemas (phase 3 spec, decision 2).
resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.this.name
  name         = "silver"
  comment      = "dbt staging and intermediate models: typed, deduplicated, aligned to 15 minutes."
}

resource "databricks_schema" "gold" {
  catalog_name = databricks_catalog.this.name
  name         = "gold"
  comment      = "dbt star schema at a 15-minute grain, for the report."
}

# Auto Loader checkpoints and schema tracking, one directory per bronze table.
resource "databricks_volume" "checkpoints" {
  catalog_name = databricks_catalog.this.name
  schema_name  = databricks_schema.bronze.name
  name         = "checkpoints"
  volume_type  = "MANAGED"
  comment      = "Auto Loader checkpoints and schema locations for the bronze load."
}

# The owner can read everything in the catalog and explore the raw files; changes go through
# Terraform and the bundle. CREATE_SCHEMA lets local dbt runs create the owner's own dev schemas
# (dev_silver, dev_gold); the owner owns those, but still can't change the schemas the CI SP owns.
# databricks_grants is authoritative for each securable.
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.this.name

  grant {
    principal  = var.owner_user_name
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "READ_VOLUME", "CREATE_SCHEMA"]
  }

  # The read-only PR principal (ADR 0016): reads everything for plans and dbt deferral, and creates
  # its own pr_<n>_* schemas for dbt PR builds. It can't change bronze, silver or gold.
  grant {
    principal  = var.pr_service_principal_id
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "CREATE_SCHEMA"]
  }
}

resource "databricks_grants" "landing" {
  external_location = databricks_external_location.landing.id

  grant {
    principal  = var.owner_user_name
    privileges = ["READ_FILES"]
  }
}
