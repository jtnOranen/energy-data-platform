# unity_catalog

Unity Catalog objects, created with the `databricks` provider by the CI service principal (which then
owns them):

- Storage credential `<project>-<env>-adls` pointing at the access connector from `modules/databricks`.
- External locations `landing` (read-only, raw files) and `lake` (catalog managed storage).
- Catalog `<project>` with its managed storage under the `lake` location, schema `bronze`, and the
  managed volume `bronze.checkpoints` for Auto Loader.
- Grants for the owner: read everything in the catalog, read the raw files in `landing`.

`silver` and `gold` schemas come in phase 3.

The CI service principal must be a workspace admin, which `infra/bootstrap/bootstrap.sh` takes care
of. Workspace admins of an auto-enabled workspace hold `CREATE STORAGE CREDENTIAL`,
`CREATE EXTERNAL LOCATION` and `CREATE CATALOG` on the metastore, which is all this module needs.

Auth: in CI the provider uses `DATABRICKS_AUTH_TYPE=github-oidc-azure` (the same Entra ID federated
credential as `azurerm`); locally it falls back to the owner's `az login`.
