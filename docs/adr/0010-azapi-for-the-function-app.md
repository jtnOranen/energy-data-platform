# 0010 — azapi for the Flex Consumption function app

- Status: accepted
- Date: 2026-10-20

## Context

ADR 0008 chose Flex Consumption with identity-based host storage, so no storage key is needed. In
azurerm 4.81, `azurerm_function_app_flex_consumption` always injects an `AzureWebJobsStorage`
connection string. With identity-based authentication that string has an empty account key, and the
Functions host reads it before `AzureWebJobsStorage__accountName`. The two possible outcomes are an app
that can't reach its host storage, or (if the value is overridden with `""`) a plan that never becomes
empty. This is reported in hashicorp/terraform-provider-azurerm#33211; the fix (#29099) was still open
on 2026-10-20.

## Options

1. `azapi_resource` for the function app (`Microsoft.Web/sites`), everything else in azurerm. azapi
   sends the ARM body as written and adds nothing.
2. azurerm with `AzureWebJobsStorage = ""` and `ignore_changes` on that key. This converges, but a
   later change to any other app setting makes the provider silently re-inject the broken value.
3. Key-based host storage (`StorageAccountConnectionString`). This works in azurerm, but puts a
   storage key in Terraform state and app settings, which goes against ADR 0008.

## Decision

Option 1. Only the function app itself uses azapi (`Microsoft.Web/sites@2024-11-01`, with schema
validation on). The plan, storage, monitoring and role assignments stay in azurerm.

## Consequences

One extra provider (`azure/azapi`, pinned to major version 2), and the function app is written as an
ARM body (`functionAppConfig`, `siteConfig.appSettings`) instead of azurerm arguments. Once #29099 is
released, the resource can move back to `azurerm_function_app_flex_consumption` with a `moved`/import
step. The post-apply `plan -detailed-exitcode` check in CI will show whether azapi's handling of
`appSettings` (which Azure doesn't return on a plain GET) converges.
