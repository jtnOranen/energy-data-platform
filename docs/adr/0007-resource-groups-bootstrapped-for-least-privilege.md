# 0007 — Resource groups are bootstrapped, so the CI identity can be scoped to them

- Status: accepted
- Date: 2026-10-20

## Context

The Azure subscription used for this project is the owner's personal subscription, which
may also hold unrelated personal resources now or in the future. The GitHub Actions
service principal (`gh-energy-data-platform`) originally held `Contributor` and
`Role Based Access Control Administrator` at the **subscription** scope, because
`infra/envs/dev/main.tf` had Terraform create `rg-energy-dev` itself, and creating a
resource group is a subscription-level operation that cannot be scoped to a resource
group that doesn't exist yet. A compromised or malicious workflow run (see ADR 0004's
fork-PR note) would therefore have been able to touch anything in the subscription, not
just this project.

## Options

1. Keep Terraform creating `rg-energy-dev`, accept subscription-scoped `Contributor` /
   `RBAC Administrator` for the SP.
2. Create `rg-energy-dev` outside Terraform (in `infra/bootstrap/bootstrap.sh`, run by the
   owner's own account), and have Terraform read it via a `data` source. The SP's roles
   can then be scoped to just `rg-energy-dev` (and `rg-energy-tfstate` isn't needed by the
   SP at all -- Terraform never manages anything inside it, only the state blob, which is
   already a separate, narrower `Storage Blob Data Contributor` grant on the storage
   account itself).
3. Move the whole project to its own Azure subscription for full isolation.

## Decision

Option 2. `bootstrap.sh` now creates both `rg-energy-tfstate` and `rg-energy-dev`;
`infra/envs/dev/main.tf` reads the dev resource group via `data "azurerm_resource_group"
"dev"` instead of creating it. The SP's `Contributor` and `RBAC Administrator` roles are
scoped to `rg-energy-dev` only. The SP now has zero subscription-level permissions and
cannot read, write or delete anything outside `rg-energy-dev` (or the tfstate storage
account's blobs) -- including any other, unrelated resource in this personal subscription.

Option 3 would be stronger still (a compromised SP in option 2 could still exhaust the
dev resource group's budget or create resources there), but needs manual portal work to
provision a second subscription under a personal account, and the project's roadmap
assumes one subscription. Not pursued now; worth revisiting if this ever stops being a
single-person learning project.

## Consequences

Every future phase's Azure resources must live inside `rg-energy-dev`, or `bootstrap.sh`
needs to create (and the SP needs scoping to) another named resource group -- there's no
longer a blanket subscription-level grant to fall back on. This is consistent with
`docs/architecture.md`'s "one environment, dev" design.
