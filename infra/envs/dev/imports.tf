# One-off re-import after the workspace was recreated as serverless (ADR 0013). The databricks
# provider records the workspace ID in each Unity Catalog resource's state, so the old entries
# failed to refresh ("workspace_id mismatch") although the objects live in the metastore and were
# unchanged. They were removed from state with `terraform state rm module.unity_catalog` and are
# imported back here. Delete this file once the import has been applied.

import {
  to = module.unity_catalog.databricks_storage_credential.adls
  id = "energy-dev-adls"
}

import {
  to = module.unity_catalog.databricks_external_location.landing
  id = "landing"
}

import {
  to = module.unity_catalog.databricks_external_location.lake
  id = "lake"
}

import {
  to = module.unity_catalog.databricks_catalog.this
  id = "energy"
}

import {
  to = module.unity_catalog.databricks_schema.bronze
  id = "energy.bronze"
}

import {
  to = module.unity_catalog.databricks_volume.checkpoints
  id = "energy.bronze.checkpoints"
}

import {
  to = module.unity_catalog.databricks_grants.catalog
  id = "catalog/energy"
}

import {
  to = module.unity_catalog.databricks_grants.landing
  id = "external_location/landing"
}
