# Energy data platform

> One sentence on the question + one finding from the data. *(fill in phase 5)*

How wind power and weather show up in the Finnish day-ahead electricity price — an end-to-end data platform on
Azure and Databricks, built with Terraform, dbt and GitHub Actions.

![Architecture](docs/architecture.png) <!-- or link to docs/architecture.md -->

## Report

*(screenshots + one-line finding per question, phase 5)*

## Stack

Azure Functions · ADLS Gen2 · Key Vault · Databricks (Unity Catalog, Auto Loader, Workflows, Asset Bundles) ·
dbt · Terraform · GitHub Actions (OIDC)

## Run it yourself

### Bootstrap (once)

```bash
az login
GITHUB_OWNER=<you> ./infra/bootstrap/bootstrap.sh
```

Creates the Terraform state storage, a service principal with OIDC federated credentials and the GitHub repo variables.

### Deploy

Open a pull request; merging to `main` deploys everything.

## Design decisions

See [docs/adr](docs/adr). Highlights: [ingestion](docs/adr/0002-azure-function-for-ingestion.md),
[dbt](docs/adr/0003-dbt-for-transformations.md), [OIDC](docs/adr/0004-oidc-for-ci-authentication.md),
[UTC and 15-minute grain](docs/adr/0005-utc-and-15-minute-grain.md).

## Data quality

*(what is tested and why, phase 3)*

## Cost

*(actual monthly cost, phase 6)*

## Limitations and next steps

*(phase 6)*

## Data sources and licences

Fingrid open data, ENTSO-E Transparency Platform, Finnish Meteorological Institute open data. See
[docs/data-sources.md](docs/data-sources.md).
