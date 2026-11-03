# Design notes

Short answers to the questions a reviewer is likely to ask about this platform, grouped by topic.
Each links the decision record (ADR) or phase spec with the full reasoning. The phase specs in
[docs/phases](phases) list these questions under "Interview notes to capture".

## Identity and security

**Why is the Terraform state bootstrapped outside Terraform?** Terraform can't store its state in a
storage account it is about to create: there is nowhere to put the state of that first apply.
`infra/bootstrap/bootstrap.sh` creates the state account once, as the owner, together with the
other things that need more rights than CI has (resource groups, the Databricks workspace, the CI
identities). It is idempotent, and the phase 6 rebuild re-ran it without changes.
([ADR 0007](adr/0007-resource-groups-bootstrapped-for-least-privilege.md),
[ADR 0012](adr/0012-databricks-workspace-bootstrapped.md))

**Why OIDC instead of a client secret?** GitHub issues a short-lived token per workflow run, and
Entra ID trusts it through a federated credential bound to this repository and to `main`, pull
requests or the `dev` environment. There is no secret to leak, rotate or store in GitHub; the
repository variables hold only IDs. ([ADR 0004](adr/0004-oidc-for-ci-authentication.md))

**Why does the CI principal hold RBAC Administrator, and what is the risk?** Terraform creates role
assignments (the function's identity on Key Vault and landing, the access connector on the lake),
which needs the right to assign roles. It is scoped to `rg-energy-dev` only, so the principal can't
touch anything else in the subscription. Inside that resource group it could still grant any role,
itself included; a role assignment condition limiting which roles it may assign would close that
(see the README's limitations). ([ADR 0007](adr/0007-resource-groups-bootstrapped-for-least-privilege.md))

**What can the read-only PR identity do, and why do PR plans run with `-lock=false`?** Pull
requests run as a second principal with Reader on the resource group, read access to the state and
the right to create its own `pr_<n>` schemas for dbt builds. It can't write to bronze, silver or
gold or change any resource. A reader can't take the state blob's lease, so PR plans don't lock
(only `main`'s locked plan is ever applied), and they skip the refresh, because two reads (warehouse
permissions, the storage credential) need more than read rights.
([ADR 0016](adr/0016-read-only-identity-for-pull-requests.md))

**Why SHA pins and Dependabot instead of action tags?** A tag can be moved to different code; a
commit SHA can't, so a compromised action release can't change what our workflows run. Dependabot
opens PRs to move the pins, which then go through the same checks as any change.
([phase 4](phases/phase-4-ci-cd.md))

**Why are the repository settings a `gh` script and not Terraform?** Terraform's GitHub provider
needs a GitHub token stored as a secret, which the project avoids everywhere else. The settings
(merge rules, the `dev` environment, branch protection, Pages) change rarely and need the owner's
rights anyway, like `bootstrap.sh`. ([phase 4](phases/phase-4-ci-cd.md))

## Ingestion

**Why write raw responses unchanged?** Landing is the system of record: if parsing turns out to be
wrong, bronze can be rebuilt from the original bytes. The function only pages and detects error
responses (which are logged, not written). ([phase 1](phases/phase-1-ingestion.md))

**Why a 48-hour overlap window instead of "since last run"?** It makes every run independent of the
previous one: a failed run, an API outage or late data is fetched again by the next runs without any
state to keep. The cost is duplicates, which silver removes (latest fetch wins). In the rebuild
test the function was gone for an hour and the window covered it.
([phase 1](phases/phase-1-ingestion.md))

**Why one function per source?** One failing API doesn't stop the others, and each source shows
up separately in monitoring and alerts. Fingrid's three datasets share a function because its rate
limit is per API key. ([phase 1](phases/phase-1-ingestion.md))

**How does the backfill stay within the rate limits?** It reuses the function's client code, which
has a rate limiter (Fingrid one request per two seconds) and retries on 429 and 5xx with
`Retry-After`, and it chunks each request to the API's maximum range (ENTSO-E one year).
([phase 1](phases/phase-1-ingestion.md))

**Why Key Vault references and identity-based storage instead of connection strings?** The
function app's managed identity reads the API keys from Key Vault and writes to landing; storage
accounts have Shared Key disabled. No key or connection string exists anywhere to leak.
([ADR 0008](adr/0008-flex-consumption-for-the-function-app.md),
[ADR 0010](adr/0010-azapi-for-the-function-app.md))

## Bronze on Databricks

**Why serverless jobs and not a cluster?** The load is a few minutes once a day. A classic cluster
would bill its start-up every run and needs VM quota; serverless starts in seconds and bills only
while it runs. Standard performance mode trades a possible few minutes' start delay for a lower
price, which a daily batch doesn't notice. The workspace itself is serverless-only, which removed an
idle NAT gateway that cost more than the whole budget.
([ADR 0011](adr/0011-serverless-jobs-for-bronze.md), [ADR 0013](adr/0013-serverless-workspace.md))

**Why Auto Loader with `availableNow`?** It keeps track of which files it has loaded (checkpoint),
so each run loads exactly the new files and stops: batch cost, streaming bookkeeping. A continuous
stream would keep compute running for a few files an hour; re-reading the whole folder would grow
with history. In the rebuild, empty checkpoints made it reload all 3,124 files in 11 minutes.
([phase 2](phases/phase-2-databricks-bronze.md))

**Why does bronze explode arrays but keep strings?** Bronze keeps values exactly as sent, so a
parsing decision can be changed in silver without reloading. Exploding is the one transformation,
because a 20,000-record page in one row can't be queried. Explicit schemas with `_rescued_data`
mean a new source field is kept, not dropped and not a failed load.
([phase 2](phases/phase-2-databricks-bronze.md))

**Why is `_ingested_at` the fetch time and not the load time?** It is when the data was true at
the source, which is what deduplication needs ("latest fetch wins"), and it comes from the file
name, so reloading gives the same values. That made the rebuild comparable row for row.
([phase 2](phases/phase-2-databricks-bronze.md))

**How do the access connector, storage credential and external locations fit together?** The
access connector is an Azure managed identity with storage roles on the containers; the storage
credential registers it in Unity Catalog; the external locations grant use of a path under that
credential. `landing` is read-only (the connector has only Reader on it) because the function is
its only writer; `lake` holds the catalog's managed tables.
([phase 2](phases/phase-2-databricks-bronze.md))

## Modelling with dbt

**Why deduplicate ENTSO-E per delivery period, not per point?** ENTSO-E's A03 curves omit positions
whose price repeats. Mixing points from two fetches of the same period could mix their gaps, so
staging keeps one whole document per period (highest revision, then latest fetch), and
intermediate forward-fills the omitted positions with an `is_price_filled` flag.
([phase 3](phases/phase-3-dbt-star-schema.md), [data model](data-model.md))

**Why a time spine and null measures instead of dropping missing intervals?** Fingrid has gaps. A
spine gives every UTC day exactly 96 quarter-hours, which a test checks, so a missing value shows
as null instead of a silently missing row that would skew averages.
([ADR 0005](adr/0005-utc-and-15-minute-grain.md))

**Why are facts keyed by UTC but carry local date and time keys?** UTC has no DST ambiguity, so it
is the key; the report questions are about Finnish days and hours, so `date_key` and `time_key` are
local. Local days have 92, 96 or 100 intervals, and on the autumn DST day 03:00–03:45 occurs twice
and shares a `time_key`, which is right for hour-of-day profiles.
([ADR 0005](adr/0005-utc-and-15-minute-grain.md), [phase 3](phases/phase-3-dbt-star-schema.md))

**Why incremental merge with a 3-day lookback?** Each run rebuilds the last 3 days, more than the
48-hour fetch overlap, so late and revised data replaces earlier rows while a daily run stays
small. `--full-refresh` rebuilds from silver after a logic change.
([phase 3](phases/phase-3-dbt-star-schema.md))

**What do model contracts enforce on Databricks?** Column names and types, and `not_null`, are
enforced when the table is built. Primary and foreign keys are informational in Unity Catalog: they
document the model and help the optimizer, but the `unique` and `relationships` tests do the
enforcing. ([phase 3](phases/phase-3-dbt-star-schema.md))

**Why a seed and a snapshot for station metadata?** Four stations don't justify another ingestion.
The seed holds them; the snapshot turns edits to it into SCD2 history, so each weather row points
to the station version valid at that time. ([phase 3](phases/phase-3-dbt-star-schema.md))

**Why a daily dbt job and not after every bronze load?** The smallest SQL warehouse costs about
$2.80 an hour, and the day-ahead price is published once a day; a daily build keeps the report
current within the budget. ([ADR 0014](adr/0014-daily-dbt-job-on-serverless.md))

## CI/CD

**Why a single gate check instead of requiring each workflow?** Path filters skip workflows a PR
doesn't touch, and a required check that never runs blocks the PR forever. One `ci.yml` decides
what runs and a gate job always reports, so branch protection needs one check, and `main` deploys
in a fixed order. ([ADR 0015](adr/0015-single-ci-entry-point-with-a-gate-check.md))

**How does slim CI build only what changed?** The PR build compares against the production
manifest from the last `main` run: `state:modified+` selects changed models and everything
downstream, and `--defer` reads unchanged ones from production. The incremental facts use the last
30 days, so a PR build takes seconds of warehouse time. ([phase 4](phases/phase-4-ci-cd.md))

## Reporting and monitoring

**Why is the report logic in dbt models and not in the dashboard?** The `rpt_*` models are tested,
linted, under contracts and visible in lineage (an exposure links the dashboard); SQL in a
dashboard is none of those. The dashboard only selects.
([phase 5](phases/phase-5-report-monitoring.md))

**Why alert on two failures in three hours?** The 48-hour window refetches after a single failure,
so one failure needs no action; two in a row is a real outage. An email per failure would mean one
an hour during an outage like ENTSO-E's in October. Freshness alerts come from the dbt job:
`dbt source freshness` fails it when bronze is over 24 hours old, and a failed job emails.
([phase 5](phases/phase-5-report-monitoring.md))

**How do the dashboards' credentials work, and who publishes them?** The bundle (deployed by the CI
principal) publishes them without embedded credentials: embedding would require the bundle to run
as whoever deploys, which fails validation for the read-only PR principal. Viewers query with their
own rights; the owner, the only viewer, has them.
([phase 5](phases/phase-5-report-monitoring.md))

**What do the system tables give for free?** Job runs and task timings (`system.lakeflow`) and DBU
usage with list prices (`system.billing`), which the pipeline-health dashboard shows without any
custom logging. Reading them needs grants only an account admin can give, so they are in
`bootstrap.sh`. ([phase 5](phases/phase-5-report-monitoring.md))

## Rebuild and cost

**What does "rebuildable" mean here?** Everything Terraform and the Asset Bundle own can be
destroyed and recreated by CI alone. `bootstrap.sh` owns what needs the owner's rights (resource
groups, state, workspace, identities) and stays. Two things are restored, not recreated: the
landing files (the only copy of the history) and the two API keys. The test on 2026-11-02 brought
every bronze row and every gold sum back identical, and found seven problems on the way.
([rebuild runbook](rebuild.md), [phase 6](phases/phase-6-polish.md))

**Why pin resource names instead of letting a rebuild generate new ones?** A random suffix in the
state would give a rebuilt storage account, Key Vault and function app new names, and everything
that refers to them would need editing. A fixed suffix keeps every name and URL; the only ID that
changes, the SQL warehouse's, is looked up by name. ([phase 6](phases/phase-6-polish.md))

**Why does the destroy run in CI behind a typed confirmation, with `force_destroy` off otherwise?**
No local apply or destroy is a project rule: everything that changes infrastructure is logged in
CI. The typed `destroy dev` and the `main`-only check make a destroy impossible by accident.
`force_destroy` lets Terraform drop the catalog with tables it doesn't know about, so it is set only
for that run; a mistaken plan elsewhere can't drop the data. ([phase 6](phases/phase-6-polish.md))

**What does the platform cost?** About 0.30 EUR a day (9 EUR a month) since late October, almost
all of it Databricks: the daily dbt build on the SQL warehouse and the daily bronze load. Running
bronze four times a day and Databricks' predictive optimization had made a quiet day about 0.85
EUR; a daily bronze load and turning predictive optimization off cut that by two thirds. The
rebuild cost about 1 USD of extra Databricks compute.
([ADR 0017](adr/0017-daily-bronze-load-and-no-predictive-optimization.md), README "Cost")
