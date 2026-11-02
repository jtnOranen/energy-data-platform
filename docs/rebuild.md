# Rebuilding dev

How to destroy everything Terraform and the Asset Bundle own in `dev` and rebuild it from the
repository, then prove the data came back unchanged. This is the phase 6 rebuild test
(`docs/phases/phase-6-polish.md`); the same steps restore the platform after a real loss.

## What is destroyed, what stays

| Destroyed and rebuilt from the repository | Stays (`bootstrap.sh` owns it) | Restored by hand |
| --- | --- | --- |
| Storage accounts, function app, Key Vault, Log Analytics, App Insights, alerts, budget, access connector | The Databricks workspace | `landing`: backed up and uploaded again |
| Unity Catalog: storage credential, external locations, catalog, schemas, tables, volume, grants | The resource groups, the Terraform state | The two API keys in Key Vault |
| SQL warehouse; bundle jobs and dashboards | Entra ID apps, federated credentials, GitHub variables | |

Names don't change (fixed `suffix`), so no file needs editing. The warehouse gets a new ID, which
nothing in the repository names (CI and the bundle look it up by name). The owner's local dbt
schemas (`dev_*`) go with the catalog.

The function writes nothing while it is gone. Each run fetches the last 48 hours, so a rebuild
finished well within two days loses no data.

## Before you start

- A copy of the two API keys outside Azure (Key Vault → Secrets → `fingrid-api-key`,
  `entsoe-token` → Show Secret Value). The destroy can't keep them (step 4).
- About 1 GB of free disk for the landing backup, `az login` as the owner, Git Bash.
- No PR merging meanwhile, and not between 06:30 and 07:45 UTC (the scheduled jobs).

## Steps

### 1. Baseline

Pick the cutoff: **00:00 UTC two days before today** (nothing older is fetched again, so
everything before it must come back identical). Put it in the query below, run it in the SQL
editor, and keep the result.

```sql
with params as (select timestamp'2026-11-01 00:00:00' as cutoff)  -- edit
select 'bronze.fingrid_wind_production' as relation, count(*) as row_count,
       count(distinct _source_file) as files, null as sum_1, null as sum_2, null as sum_3
from energy.bronze.fingrid_wind_production, params where _ingested_at < cutoff
union all
select 'bronze.fingrid_consumption', count(*), count(distinct _source_file), null, null, null
from energy.bronze.fingrid_consumption, params where _ingested_at < cutoff
union all
select 'bronze.fingrid_production', count(*), count(distinct _source_file), null, null, null
from energy.bronze.fingrid_production, params where _ingested_at < cutoff
union all
select 'bronze.entsoe_day_ahead_price', count(*), count(distinct _source_file), null, null, null
from energy.bronze.entsoe_day_ahead_price, params where _ingested_at < cutoff
union all
select 'bronze.fmi_observations', count(*), count(distinct _source_file), null, null, null
from energy.bronze.fmi_observations, params where _ingested_at < cutoff
union all
select 'gold.fct_power_15min', count(*), count(price_eur_mwh), round(sum(price_eur_mwh), 2),
       round(sum(wind_production_mw), 2), round(sum(consumption_mw) + sum(production_mw), 2)
from energy.gold.fct_power_15min, params where interval_start_utc < cutoff
union all
select 'gold.fct_weather_15min', count(*), sum(observation_count), round(sum(temperature_c), 2),
       round(sum(wind_speed_ms), 2), null
from energy.gold.fct_weather_15min, params where interval_start_utc < cutoff
union all
select 'gold.dim_date', count(*), null, null, null, null from energy.gold.dim_date
union all
select 'gold.dim_weather_station', count(*), count_if(is_current), null, null, null
from energy.gold.dim_weather_station
```

### 2. Back up landing

```bash
mkdir -p ~/landing-backup
az storage blob download-batch --account-name stenergydevua7j --auth-mode login \
  --source landing --destination ~/landing-backup --output none
find ~/landing-backup -type f | wc -l   # about 3,000 files, 650 MB on 2026-11-01
```

### 3. Destroy

GitHub → Actions → **Destroy dev** → Run workflow (branch `main`), and type `destroy dev`. It runs
`databricks bundle destroy`, applies `allow_destroy` (force_destroy on the catalog and schemas), and
runs `terraform destroy`. Afterwards `rg-energy-dev` holds only the workspace `dbw-energy-dev` and
the action group "Application Insights Smart Detection", which Azure created along with App
Insights and Terraform doesn't own.

If it stops half-way, run it again; both destroys pick up where they left off.

### 4. Purge the Key Vault

The destroy leaves the vault soft-deleted (Terraform neither purges it nor recovers it: both act on
a subscription-level object the CI principal can't reach). Purge it so the apply can create it
again with the same name:

```bash
az keyvault purge --name kv-energy-dev-ua7j
```

### 5. Re-run bootstrap

```bash
GITHUB_OWNER=jtnOranen ./infra/bootstrap/bootstrap.sh
```

Everything it owns still exists, so it should only report that. This shows it is idempotent.

### 6. Rebuild

GitHub → Actions → **CI** → Run workflow (branch `main`). By hand it treats every part as changed:
Terraform applies and checks that a second plan is empty, then the function is deployed, then the
bundle. If the apply fails creating an external location with a permission error, run it again:
new role assignments take a few minutes to reach Azure Storage.

### 7. API keys

Key Vault `kv-energy-dev-ua7j` → Secrets → **Generate/Import**: `fingrid-api-key` and
`entsoe-token`, the values from your copy. In the portal, not on the command line, so they don't end
up in the shell history. The function reads them on its next run; until then its runs fail, which
the 48-hour window makes up for.

### 8. Restore landing

```bash
az storage blob upload-batch --account-name stenergydevua7j --auth-mode login \
  --destination landing --source ~/landing-backup --output none
```

Your Storage Blob Data Contributor on `landing` comes back with the apply; if the upload is refused,
wait a few minutes. Files the function wrote since step 6 aren't touched (every name is unique).

### 9. Load and build

Databricks → Jobs: run **bronze_load** (empty checkpoints, so it loads every file; about 35
minutes), then **dbt_build**.

### 10. Compare

Run the baseline query again with the **same cutoff**. Every row must match step 1.

### 11. Check the rest

- Both dashboards render with current data (new IDs; Dashboards → energy_report, pipeline_health).
- The CI run's apply job ended with "No changes" after the apply.
- The function's next hourly runs succeed (App Insights → Transaction search, or the
  pipeline-health dashboard).
- A failed job still emails the owner: run **bronze_rebuild** with `source=alert-probe`.
- The next scheduled `bronze_load` (06:30 UTC) and `dbt_build` (07:15) succeed.

Then delete `~/landing-backup`, and record the time each step took, the cost and anything that
needed a manual fix in the phase 6 spec.
