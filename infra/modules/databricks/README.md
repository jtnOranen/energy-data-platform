# databricks

Azure-side pieces Unity Catalog needs to reach the ADLS account. The workspace itself is **not** here:
`infra/bootstrap/bootstrap.sh` creates it as a serverless workspace, so the CI service principal needs
no subscription-level rights (ADRs 0012, 0013). `envs/dev/main.tf` reads it with a data source.

- An access connector (`dbac-<project>-<env>`) with a system-assigned identity. A Unity Catalog storage
  credential points at it, so Databricks reaches storage without keys or secrets.
- Four roles for that identity:
  - Reader on the access connector itself: Unity Catalog requires it to register the storage
    credential when the caller (the CI SP with GitHub OIDC) can't prove its own Azure role on the
    connector. Without it: "Registering a credential requires managed identity (MI) to have a Reader
    role scoped to MI itself".
  - Storage Blob Delegator on the account: needed whenever data roles are scoped to containers, since
    Unity Catalog uses user delegation SAS tokens. Gives no data access on its own.
  - Storage Blob Data Reader on `landing`: bronze only reads raw files.
  - Storage Blob Data Contributor on `lake`: the catalog's managed storage.
