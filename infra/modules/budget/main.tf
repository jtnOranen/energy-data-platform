# Azure requires a monthly budget's start_date to be the first of a month. Recomputing it
# from timestamp() on every plan would show a permanent diff, so changes to it are ignored
# after the first apply pins it to that month.
resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "budget-${var.project}-${var.env}"
  resource_group_id = var.resource_group_id

  amount     = var.budget_amount_eur
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    contact_emails = [var.alert_email]
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}
