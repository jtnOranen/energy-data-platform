# budget

Monthly consumption budget on the resource group, with email alerts at 80% and 100% of
`budget_amount_eur` (actual cost), and when the month's *forecasted* cost exceeds 100%. It covers
everything in the resource group, including the Databricks workspace's DBUs (serverless included).
It alerts; it doesn't stop anything. `start_date` is pinned to the month of the first apply and then
ignored -- see the comment in `main.tf` for why.
