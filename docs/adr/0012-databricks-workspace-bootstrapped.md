# 0012 — The Databricks workspace is bootstrapped, not created by Terraform

- Status: accepted
- Date: 2026-10-22

## Context

An Azure Databricks workspace creates a managed resource group (`rg-energy-dev-dbw-managed`) for its
own resources. Creating a resource group is a subscription-level operation, and Microsoft documents
the requirement for creating a workspace as `Contributor`/`Owner` on the subscription, or a custom role
that includes `Microsoft.Resources/subscriptions/resourceGroups/write`. The CI service principal has
rights only inside `rg-energy-dev` (ADR 0007), so it can't create the workspace.

## Options

1. Give the CI SP a narrow custom role on the subscription (`resourceGroups/read` and `/write` only),
   keeping the workspace in Terraform. The SP could then create empty resource groups and edit the tags
   of any resource group in the subscription.
2. Create the workspace in `infra/bootstrap/bootstrap.sh` as the owner, like the resource groups, and
   read it in Terraform with a `data` source.

## Decision

Option 2. It keeps the rule from ADR 0007 intact: anything that needs subscription-level rights is done
once by the owner, and the CI identity has no rights outside `rg-energy-dev`. A workspace is created
once and rarely changed, much like a resource group, so losing Terraform's plan/drift view of it costs
little.

## Consequences

- Workspace settings (SKU, tags, managed resource group name) live in `bootstrap.sh`. Changing them means
  editing the script and re-running it; `terraform plan` won't show drift on the workspace itself.
- Everything around the workspace stays in Terraform: access connector, storage container, role
  assignments and all Unity Catalog objects.
- The CI SP is a workspace admin through its `Contributor` role on `rg-energy-dev`, which the workspace
  inherits; no extra grant is needed.
- The phase 6 rebuild test must run `bootstrap.sh` before `terraform apply`, which was already the case
  for the resource groups. Deleting the workspace isn't part of `terraform destroy`.
