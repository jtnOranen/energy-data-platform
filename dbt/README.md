# dbt

bronze → silver → gold for the energy platform (`docs/phases/phase-3-dbt-star-schema.md`,
`docs/data-model.md`). Runs on the serverless SQL warehouse `energy-dev`.

## Setup (from the repo root)

```bash
uv sync --group dbt
cd dbt
export DBT_PROFILES_DIR=.   # profiles.yml lives here and holds no secrets
uv run dbt deps
```

## Run locally (target `dev`)

Writes to your own schemas `dev_silver` and `dev_gold`, never to `silver`/`gold` (see
`macros/generate_schema_name.sql`). Two ways to log in:

- **Browser (OAuth):** just run dbt; the first command opens a login page.
- **Entra ID token from `az`** (no browser, valid about an hour):

  ```bash
  export DBT_DATABRICKS_TOKEN=$(az account get-access-token \
    --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
  ```

  `2ff814a6-…` is the fixed application ID of Azure Databricks, not a secret.

```bash
uv run dbt build                 # models + tests
uv run dbt build -s staging      # one folder
uv run dbt source freshness
uv run sqlfluff lint models      # needs a login too: the dbt templater compiles the project
```

## Targets

| Target | Who | Auth | Schemas |
| --- | --- | --- | --- |
| `dev` | owner, locally | OAuth or `DBT_DATABRICKS_TOKEN` | `dev_silver`, `dev_gold` |
| `ci` | GitHub Actions (`dbt.yml`) | Entra ID token from OIDC | parse and lint only, nothing built |
| `prod` | the Databricks job (PR E) | `DBT_ACCESS_TOKEN` injected by Databricks | `silver`, `gold` |

## Layout

- `models/staging/`: one model per bronze table, typed and deduplicated (latest fetch wins; ENTSO-E
  per whole delivery period). Views in `silver`.
- `macros/generate_schema_name.sql`: production names only for `prod`.
- `.sqlfluff`: dbt templater, Databricks dialect, lowercase keywords.
