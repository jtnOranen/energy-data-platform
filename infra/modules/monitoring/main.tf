# Failure alerts for the ingestion functions (phase 5, deliverable A). Databricks job failures alert
# from the bundle (job email notifications); the budget has its own alerts.

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${var.project}-${var.env}"
  resource_group_name = var.resource_group_name
  short_name          = "${var.project}-${var.env}" # shown in the email; at most 12 characters
  tags                = var.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Two or more failed runs of the same function in three hours (phase 5 spec, decision 4). A single
# failure, like one ENTSO-E outage hour, stays quiet: the next run's 48-hour window refetches it.
# One rule split by function name (one time series each), evaluated hourly, resolving itself once a
# window passes without failures.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "function_failures" {
  name                = "alert-${var.project}-${var.env}-function-failures"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "An ingestion function failed at least twice in three hours."
  scopes              = [var.application_insights_id]
  severity            = 2
  enabled             = true

  evaluation_frequency    = "PT1H"
  window_duration         = "PT3H"
  auto_mitigation_enabled = true

  criteria {
    query                   = <<-KQL
      requests
      | where success == false
      | summarize failures = count() by name
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "failures"
    operator                = "GreaterThanOrEqual"
    threshold               = 2

    dimension {
      name     = "name"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}
