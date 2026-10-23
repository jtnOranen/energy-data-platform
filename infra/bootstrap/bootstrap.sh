#!/usr/bin/env bash
#
# Idempotent bootstrap for everything that needs the owner's rights rather than the CI service
# principal's: the Terraform state backend, the resource groups and the Databricks workspace
# (subscription-level operations), and the GitHub Actions identities (Entra ID operations). Terraform
# does everything else. Safe to re-run (it checks before creating anything, per
# docs/phases/phase-0-foundation.md); re-run it when a phase changes one of these.
#
# Usage:
#   az login
#   GITHUB_OWNER=<your-github-username-or-org> ./infra/bootstrap/bootstrap.sh
#
# Optional:
#   LOCATION=swedencentral  (default)

set -euo pipefail

# On Git Bash / MSYS2 (common on Windows), arguments that look like absolute POSIX paths
# (e.g. "/subscriptions/...") get silently rewritten to Windows paths before reaching
# az.exe, breaking --scope. This disables that rewriting; harmless on Linux/macOS.
export MSYS_NO_PATHCONV=1

GITHUB_OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER, e.g. GITHUB_OWNER=jtnOranen ./bootstrap.sh}"
LOCATION="${LOCATION:-swedencentral}"

REPO="energy-data-platform"
RESOURCE_GROUP="rg-energy-tfstate"
DEV_RESOURCE_GROUP="rg-energy-dev"
DATABRICKS_WORKSPACE="dbw-energy-dev"
CONTAINER_NAME="tfstate"
SP_NAME="gh-energy-data-platform"
# Pull requests run as this one: it can read the platform but not change it (ADR 0016).
PR_SP_NAME="gh-energy-data-platform-pr"

echo "==> Checking az and gh login"
az account show >/dev/null
gh auth status >/dev/null

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> Resource group: $RESOURCE_GROUP ($LOCATION)"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags project=energy env=tfstate managed_by=bootstrap-script \
  -o none

# Created here (not by Terraform) so the CI service principal's roles below can be
# scoped to this resource group instead of the whole subscription -- creating a resource
# group is itself a subscription-level operation, so Terraform creating it would force
# the SP to hold subscription-wide Contributor, able to touch anything else in this
# (personal) subscription. envs/dev/main.tf reads this RG via a data source, not a
# resource. See docs/adr/0004.
echo "==> Resource group: $DEV_RESOURCE_GROUP ($LOCATION)"
az group create \
  --name "$DEV_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags project=energy env=dev managed_by=bootstrap-script \
  -o none

# Also created here, not by Terraform, so the CI service principal never needs subscription-level
# rights for it (ADR 0012). envs/dev/main.tf reads the workspace via a data source.
# Serverless compute mode (ADR 0013): no classic compute plane, so no managed VNet, NAT gateway,
# public IP or DBFS storage account sitting idle and billing by the hour.
echo "==> Databricks workspace: $DATABRICKS_WORKSPACE"
az provider register --namespace Microsoft.Databricks --wait -o none
az extension add --name databricks --upgrade --only-show-errors -o none
if az databricks workspace show --name "$DATABRICKS_WORKSPACE" --resource-group "$DEV_RESOURCE_GROUP" \
    -o none 2>/dev/null; then
  echo "    found existing: $DATABRICKS_WORKSPACE"
  COMPUTE_MODE=$(az databricks workspace show --name "$DATABRICKS_WORKSPACE" \
    --resource-group "$DEV_RESOURCE_GROUP" --query computeMode -o tsv)
  if [[ "$COMPUTE_MODE" != "Serverless" ]]; then
    echo "    WARNING: compute mode is '${COMPUTE_MODE:-Hybrid}', not Serverless. A hybrid workspace keeps" >&2
    echo "    a NAT gateway running in its managed resource group. Delete and re-run (ADR 0013)." >&2
  fi
else
  echo "    creating (takes a few minutes): $DATABRICKS_WORKSPACE"
  az databricks workspace create \
    --name "$DATABRICKS_WORKSPACE" \
    --resource-group "$DEV_RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku premium \
    --compute-mode Serverless \
    --tags project=energy env=dev managed_by=bootstrap-script \
    -o none
fi

echo "==> Terraform state storage account"
# The suffix must stay stable across re-runs (it's part of the resource name),
# so reuse an existing account in this resource group instead of generating a
# new random suffix every time.
EXISTING_SA=$(az storage account list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'stenergytfstate')].name | [0]" -o tsv)

if [[ -n "$EXISTING_SA" ]]; then
  STORAGE_ACCOUNT="$EXISTING_SA"
  echo "    found existing: $STORAGE_ACCOUNT"
else
  # bash $RANDOM-based suffix: no extra tool dependency (openssl/python) needed.
  # "stenergytfstate" (15 chars) + 8 hex chars = 23, under the 24-char Azure limit.
  SUFFIX=$(printf '%04x%04x' "$RANDOM" "$RANDOM")
  STORAGE_ACCOUNT="stenergytfstate${SUFFIX}"
  echo "    creating: $STORAGE_ACCOUNT"
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --tags project=energy env=tfstate managed_by=bootstrap-script \
    -o none
fi

# Idempotent regardless of which branch above ran.
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-versioning true \
  -o none

echo "==> Blob container: $CONTAINER_NAME"
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  -o none

# Prints the app ID of an app registration with a service principal, creating either if missing.
ensure_app_and_sp () {
  local name="$1" app_id sp_id
  app_id=$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  if [[ -z "$app_id" ]]; then
    app_id=$(az ad app create --display-name "$name" --query appId -o tsv)
    echo "    created app registration $name: $app_id" >&2
  else
    echo "    found existing app registration $name: $app_id" >&2
  fi
  sp_id=$(az ad sp list --filter "appId eq '$app_id'" --query "[0].id" -o tsv)
  if [[ -z "$sp_id" ]]; then
    az ad sp create --id "$app_id" -o none
    echo "    created service principal for $name" >&2
  fi
  echo "$app_id"
}

echo "==> App registrations + service principals: $SP_NAME, $PR_SP_NAME"
APP_ID=$(ensure_app_and_sp "$SP_NAME")
PR_APP_ID=$(ensure_app_and_sp "$PR_SP_NAME")

echo "==> Federated credentials (OIDC, no client secret)"

# GitHub's OIDC token "sub" claim includes the owner's and repo's immutable numeric IDs
# (repo:<owner>@<owner_id>/<repo>@<repo_id>:...), not just their names, so the federated
# credential subject must match that exact format or Azure rejects the token with
# AADSTS700213. Names can be renamed later without invalidating this.
read -r OWNER_ID REPO_ID <<< "$(gh api "repos/${GITHUB_OWNER}/${REPO}" --jq '"\(.owner.id) \(.id)"')"

add_federated_credential () {
  local app_id="$1" cred_name="$2" subject="$3"
  local existing_subject
  existing_subject=$(az ad app federated-credential list --id "$app_id" \
    --query "[?name=='$cred_name'].subject | [0]" -o tsv)
  if [[ "$existing_subject" == "$subject" ]]; then
    echo "    $cred_name already up to date"
  else
    local params
    params=$(cat <<JSON
{
  "name": "$cred_name",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$subject",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)
    if [[ -z "$existing_subject" ]]; then
      az ad app federated-credential create --id "$app_id" --parameters "$params" -o none
      echo "    created $cred_name"
    else
      az ad app federated-credential update --id "$app_id" --federated-credential-id "$cred_name" --parameters "$params" -o none
      echo "    updated $cred_name (subject had changed)"
    fi
  fi
}

SUBJECT_PREFIX="repo:${GITHUB_OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}"
add_federated_credential "$APP_ID" "gh-energy-data-platform-main" "${SUBJECT_PREFIX}:ref:refs/heads/main"
# A job that declares `environment: dev` (the apply job) gets this subject instead of the
# ref:refs/heads/main one, so it needs its own credential.
add_federated_credential "$APP_ID" "gh-energy-data-platform-env-dev" "${SUBJECT_PREFIX}:environment:dev"
# Pull requests: only the read-only principal (ADR 0016).
add_federated_credential "$PR_APP_ID" "gh-energy-data-platform-pr" "${SUBJECT_PREFIX}:pull_request"

# The deploying app held the pull_request credential until phase 4 moved PR jobs to the read-only
# principal; remove it so a PR can no longer log in as the deploying identity.
if az ad app federated-credential show --id "$APP_ID" \
    --federated-credential-id "gh-energy-data-platform-pr" -o none 2>/dev/null; then
  az ad app federated-credential delete --id "$APP_ID" \
    --federated-credential-id "gh-energy-data-platform-pr" -o none
  echo "    removed gh-energy-data-platform-pr from $SP_NAME (PRs use $PR_SP_NAME)"
fi

echo "==> Role assignments"

# AAD/Graph replication can lag a few seconds after creating a new service
# principal, so a fresh role assignment occasionally fails on the first try.
# Retry a few times instead of failing the whole script.
assign_role_if_missing () {
  local app_id="$1" role="$2" scope="$3"
  local existing
  existing=$(az role assignment list --assignee "$app_id" --role "$role" --scope "$scope" \
    --query "[0].id" -o tsv)
  if [[ -n "$existing" ]]; then
    echo "    $role on $scope already assigned"
    return
  fi
  for attempt in 1 2 3 4 5; do
    if az role assignment create --assignee "$app_id" --role "$role" --scope "$scope" -o none 2>/dev/null; then
      echo "    assigned $role on $scope"
      return
    fi
    sleep 10
  done
  echo "    FAILED to assign $role on $scope after retries" >&2
  exit 1
}

# Scoped to rg-energy-dev only -- never the subscription, and not even
# rg-energy-tfstate (Terraform never manages anything in that resource group; it only
# needs data-plane blob access, granted separately below).
DEV_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DEV_RESOURCE_GROUP}"
STORAGE_SCOPE=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

assign_role_if_missing "$APP_ID" "Contributor" "$DEV_RG_SCOPE"
assign_role_if_missing "$APP_ID" "Role Based Access Control Administrator" "$DEV_RG_SCOPE"
assign_role_if_missing "$APP_ID" "Storage Blob Data Contributor" "$STORAGE_SCOPE"

# Read only: Terraform plans on PRs refresh resources (Reader) and read the state without taking
# its lock (plan -lock=false; a reader can't lease the blob). See ADR 0016.
assign_role_if_missing "$PR_APP_ID" "Reader" "$DEV_RG_SCOPE"
assign_role_if_missing "$PR_APP_ID" "Storage Blob Data Reader" "$STORAGE_SCOPE"

echo "==> Service principals in the Databricks workspace"

# A Contributor on the workspace resource is normally made a workspace admin on first use, but for a
# service principal that only happens when the client also sends an Azure management token, which the
# GitHub OIDC auth used in CI (github-oidc-azure) doesn't. So add it once here, as the owner, through
# the workspace SCIM API. Terraform's databricks provider and the bundle deploy both need it.
# The PR principal joins as a regular user (no admin): what it may read is granted in Terraform.
DATABRICKS_RESOURCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" # the Azure Databricks first-party app
DATABRICKS_HOST="https://$(az databricks workspace show --name "$DATABRICKS_WORKSPACE" \
  --resource-group "$DEV_RESOURCE_GROUP" --query workspaceUrl -o tsv)"
SCIM="$DATABRICKS_HOST/api/2.0/preview/scim/v2"

dbx_rest () {
  az rest --resource "$DATABRICKS_RESOURCE" "$@"
}

# Prints the workspace ID of a service principal, adding it to the workspace if missing.
ensure_workspace_sp () {
  local app_id="$1" name="$2" dbx_id
  dbx_id=$(dbx_rest --method get \
    --url "$SCIM/ServicePrincipals?filter=applicationId%20eq%20$app_id" \
    --query "Resources[0].id" -o tsv)
  if [[ -z "$dbx_id" ]]; then
    dbx_id=$(dbx_rest --method post --url "$SCIM/ServicePrincipals" --body "$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"],
  "applicationId": "$app_id",
  "displayName": "$name",
  "entitlements": [{"value": "workspace-access"}, {"value": "databricks-sql-access"}]
}
JSON
)" --query id -o tsv)
    echo "    added $name to the workspace" >&2
  else
    echo "    $name already in the workspace" >&2
  fi
  echo "$dbx_id"
}

ADMINS_GROUP_ID=$(dbx_rest --method get --url "$SCIM/Groups?filter=displayName%20eq%20admins" \
  --query "Resources[0].id" -o tsv)
DBX_SP_ID=$(ensure_workspace_sp "$APP_ID" "$SP_NAME")
ensure_workspace_sp "$PR_APP_ID" "$PR_SP_NAME" >/dev/null
# Adding an existing member again is a no-op.
dbx_rest --method patch --url "$SCIM/Groups/$ADMINS_GROUP_ID" --body "$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
  "Operations": [{"op": "add", "value": {"members": [{"value": "$DBX_SP_ID"}]}}]
}
JSON
)" -o none
echo "    $SP_NAME is in the workspace admins group"

echo "==> GitHub repo variables (not secrets) on ${GITHUB_OWNER}/${REPO}"
gh variable set AZURE_CLIENT_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$APP_ID"
gh variable set AZURE_PR_CLIENT_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$PR_APP_ID"
gh variable set AZURE_TENANT_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$SUBSCRIPTION_ID"
gh variable set TFSTATE_RESOURCE_GROUP --repo "${GITHUB_OWNER}/${REPO}" --body "$RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --repo "${GITHUB_OWNER}/${REPO}" --body "$STORAGE_ACCOUNT"

echo ""
echo "==> Done"
echo "Resource group (tfstate): $RESOURCE_GROUP"
echo "Resource group (dev):     $DEV_RESOURCE_GROUP"
echo "Databricks workspace:     $DATABRICKS_WORKSPACE"
echo "Storage account:   $STORAGE_ACCOUNT"
echo "Blob container:    $CONTAINER_NAME"
echo "App registration:  $SP_NAME ($APP_ID)"
echo "PR app registration: $PR_SP_NAME ($PR_APP_ID)"
echo "Subscription:      $SUBSCRIPTION_ID"
echo "Tenant:             $TENANT_ID"
echo "GitHub variables set on ${GITHUB_OWNER}/${REPO}: AZURE_CLIENT_ID, AZURE_PR_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, TFSTATE_RESOURCE_GROUP, TFSTATE_STORAGE_ACCOUNT"
