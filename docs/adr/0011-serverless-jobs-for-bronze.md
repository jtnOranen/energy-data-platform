# 0011 — Serverless jobs compute for the bronze load

- Status: accepted
- Date: 2026-10-22

## Context

The bronze job runs once an hour and processes a handful of new files, usually in well under a minute
of actual work. `docs/architecture.md` originally planned single-node job clusters. A classic job
cluster takes several minutes to start, bills its VM and DBUs for that start-up every hour, and needs
vCPU quota for the chosen VM family in `swedencentral`, which new or personal subscriptions often lack.

## Options

1. Classic single-node job cluster — full control over runtime and VM size; pays for start-up every hour
   and depends on VM quota.
2. Serverless jobs compute — starts in seconds, billed only while the task runs, no quota or VM sizing;
   less control over the runtime (pinned serverless environment instead of a DBR version) and a
   different DBU price.

## Decision

Serverless jobs compute, in the standard (cost-optimised) performance mode. For a short hourly job the
start-up overhead dominates the cost of a classic cluster, and serverless removes the quota risk.

## Consequences

- No cluster configuration in the bundle; the job pins a serverless environment version and installs the
  `energy-bronze` wheel there.
- Standard performance mode may delay the start of a run by a few minutes; irrelevant for an hourly job.
- Serverless DBUs are billed to the workspace in `rg-energy-dev`, so the existing budget alert covers
  them. Record the actual cost after a week (phase 2 acceptance).
- Serverless reaches ADLS over the public endpoint. If a storage firewall is added later, serverless
  needs a network connectivity configuration (NCC) in the Databricks account.
