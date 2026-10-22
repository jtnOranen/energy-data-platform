terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

# The SQL engine for dbt (phase 3, ADR 0014). Serverless starts in seconds, so the warehouse can stop
# after one idle minute: the API allows 1, the UI only 5. One 2X-Small cluster (4 DBU/hour) is plenty
# for this data volume. The CI service principal creates and therefore owns it.
resource "databricks_sql_endpoint" "this" {
  name                      = "${var.project}-${var.env}"
  cluster_size              = "2X-Small"
  min_num_clusters          = 1
  max_num_clusters          = 1
  auto_stop_mins            = 1
  enable_serverless_compute = true
  warehouse_type            = "PRO" # required for serverless

  # A new warehouse starts right away; don't hold the apply until it's running.
  no_wait = true

  tags {
    dynamic "custom_tags" {
      for_each = var.tags
      content {
        key   = custom_tags.key
        value = custom_tags.value
      }
    }
  }
}

# The owner runs dbt locally and queries gold. databricks_permissions is authoritative; the creator
# keeps IS_OWNER regardless.
resource "databricks_permissions" "this" {
  sql_endpoint_id = databricks_sql_endpoint.this.id

  access_control {
    user_name        = var.owner_user_name
    permission_level = "CAN_USE"
  }
}
