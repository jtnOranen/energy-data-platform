# 0013 — Serverless Databricks workspace

- Status: accepted
- Date: 2026-10-22

## Context

The first workspace was created without a compute mode, so it defaulted to **Hybrid** with secure
cluster connectivity (`enableNoPublicIp = true`). A hybrid workspace always gets a managed resource
group with a VNet, network security group, NAT gateway, public IP and DBFS root storage account, for
classic clusters. This project runs only serverless compute (ADR 0011), so none of that was used, but
the NAT gateway and public IP bill by the hour: about 33 € a month together, more than the whole
20 € budget. They also sat in the managed resource group, outside the budget's scope
(`rg-energy-dev`), so the budget alert would never have fired. The owner spotted the NAT gateway.

## Options

1. Hybrid with `enableNoPublicIp = false` — no NAT gateway, but still a managed VNet and DBFS storage
   account, and classic clusters (unused) would get public IPs.
2. Serverless workspace (`computeMode = Serverless`) — no classic compute plane at all: no managed
   VNet, NAT gateway, public IP or DBFS storage. Comes with Databricks-managed default storage, and
   still connects to our ADLS through Unity Catalog.

## Decision

Option 2. It matches ADR 0011 exactly and leaves nothing idle in Azure. The compute mode can't be
changed in place, so the hybrid workspace was deleted and recreated with the same name; it held no
notebooks, jobs or data, and the Unity Catalog objects live in the metastore, not the workspace.

## Consequences

- Classic clusters are not available in this workspace. If a later phase needs one (it shouldn't; dbt
  runs on a serverless SQL warehouse), that would mean a new decision and a hybrid workspace.
- The workspace catalog uses Databricks default storage, billed through Databricks. We don't use it;
  the `energy` catalog stays in our `lake` container.
- `bootstrap.sh` warns if the existing workspace isn't serverless, so a rebuild (phase 6) can't
  silently bring the NAT gateway back.
- Lesson recorded: check what a resource creates by default, not just the options we set.
