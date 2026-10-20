# 0008 — Flex Consumption plan for the ingestion function

- Status: accepted
- Date: 2026-10-20

## Context

The ingestion Function (ADR 0002) runs three hourly timer triggers with short executions. It needs a
serverless plan that costs close to nothing at this load, and it should not need a storage connection
string, since the project avoids long-lived secrets (ADR 0004).

## Options

1. **Linux Consumption**: the original serverless plan. Host storage is normally configured with a
   connection string that contains the storage account key.
2. **Flex Consumption**: the newer serverless plan Microsoft recommends for new apps. It supports a
   managed identity for host storage and deployment storage, so no account key is needed.
3. Premium or Dedicated: always-on instances. Too expensive for three short hourly jobs.

## Decision

Flex Consumption, with a system-assigned managed identity for host storage, deployment storage, Key Vault
references and the `landing` container.

## Consequences

No storage account key is stored anywhere, consistent with the rest of the platform. Flex Consumption
supports fewer regions and language versions than the older plan, so region and Python version support
in `swedencentral` must be checked before implementation (phase 1, step 0). Its Terraform resource
(`azurerm_function_app_flex_consumption`) turned out not to support identity-based host storage
correctly in azurerm 4.81, so the function app is created with azapi instead (ADR 0010).
