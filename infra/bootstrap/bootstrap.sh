#!/usr/bin/env bash
#
# Idempotent bootstrap for the energy-data-platform Terraform backend and
# GitHub Actions OIDC identity. Run once locally; safe to re-run (it checks
# before creating anything, per docs/phases/phase-0-foundation.md).
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
DATABRICKS_MANAGED_RESOURCE_GROUP="rg-energy-dev-dbw-managed"
CONTAINER_NAME="tfstate"
SP_NAME="gh-energy-data-platform"

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

# Also created here, not by Terraform: a workspace creates its own managed resource group,
# which is a subscription-level operation the CI service principal can't do. See ADR 0012.
# envs/dev/main.tf reads the workspace via a data source.
echo "==> Databricks workspace: $DATABRICKS_WORKSPACE"
az provider register --namespace Microsoft.Databricks --wait -o none
az extension add --name databricks --upgrade --only-show-errors -o none
if az databricks workspace show --name "$DATABRICKS_WORKSPACE" --resource-group "$DEV_RESOURCE_GROUP" \
    -o none 2>/dev/null; then
  echo "    found existing: $DATABRICKS_WORKSPACE"
else
  echo "    creating (takes a few minutes): $DATABRICKS_WORKSPACE"
  az databricks workspace create \
    --name "$DATABRICKS_WORKSPACE" \
    --resource-group "$DEV_RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku premium \
    --managed-resource-group "$DATABRICKS_MANAGED_RESOURCE_GROUP" \
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

echo "==> App registration + service principal: $SP_NAME"
APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
  echo "    created app registration: $APP_ID"
else
  echo "    found existing app registration: $APP_ID"
fi

SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [[ -z "$SP_OBJECT_ID" ]]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "    created service principal: $SP_OBJECT_ID"
else
  echo "    found existing service principal: $SP_OBJECT_ID"
fi

echo "==> Federated credentials (OIDC, no client secret)"

# GitHub's OIDC token "sub" claim includes the owner's and repo's immutable numeric IDs
# (repo:<owner>@<owner_id>/<repo>@<repo_id>:...), not just their names, so the federated
# credential subject must match that exact format or Azure rejects the token with
# AADSTS700213. Names can be renamed later without invalidating this.
read -r OWNER_ID REPO_ID <<< "$(gh api "repos/${GITHUB_OWNER}/${REPO}" --jq '"\(.owner.id) \(.id)"')"

add_federated_credential () {
  local cred_name="$1" subject="$2"
  local existing_subject
  existing_subject=$(az ad app federated-credential list --id "$APP_ID" \
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
      az ad app federated-credential create --id "$APP_ID" --parameters "$params" -o none
      echo "    created $cred_name"
    else
      az ad app federated-credential update --id "$APP_ID" --federated-credential-id "$cred_name" --parameters "$params" -o none
      echo "    updated $cred_name (subject had changed)"
    fi
  fi
}

add_federated_credential "gh-energy-data-platform-main" "repo:${GITHUB_OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}:ref:refs/heads/main"
add_federated_credential "gh-energy-data-platform-pr" "repo:${GITHUB_OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}:pull_request"
# A job that declares `environment: dev` (the apply job) gets this subject instead of the
# ref:refs/heads/main one, so it needs its own credential.
add_federated_credential "gh-energy-data-platform-env-dev" "repo:${GITHUB_OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}:environment:dev"

echo "==> Role assignments"

# AAD/Graph replication can lag a few seconds after creating a new service
# principal, so a fresh role assignment occasionally fails on the first try.
# Retry a few times instead of failing the whole script.
assign_role_if_missing () {
  local role="$1" scope="$2"
  local existing
  existing=$(az role assignment list --assignee "$APP_ID" --role "$role" --scope "$scope" \
    --query "[0].id" -o tsv)
  if [[ -n "$existing" ]]; then
    echo "    $role on $scope already assigned"
    return
  fi
  for attempt in 1 2 3 4 5; do
    if az role assignment create --assignee "$APP_ID" --role "$role" --scope "$scope" -o none 2>/dev/null; then
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

assign_role_if_missing "Contributor" "$DEV_RG_SCOPE"
assign_role_if_missing "Role Based Access Control Administrator" "$DEV_RG_SCOPE"
assign_role_if_missing "Storage Blob Data Contributor" "$STORAGE_SCOPE"

echo "==> Service principal as Databricks workspace admin"

# A Contributor on the workspace resource is normally made a workspace admin on first use, but for a
# service principal that only happens when the client also sends an Azure management token, which the
# GitHub OIDC auth used in CI (github-oidc-azure) doesn't. So add it once here, as the owner, through
# the workspace SCIM API. Terraform's databricks provider and the bundle deploy both need it.
DATABRICKS_RESOURCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" # the Azure Databricks first-party app
DATABRICKS_HOST="https://$(az databricks workspace show --name "$DATABRICKS_WORKSPACE" \
  --resource-group "$DEV_RESOURCE_GROUP" --query workspaceUrl -o tsv)"
SCIM="$DATABRICKS_HOST/api/2.0/preview/scim/v2"

dbx_rest () {
  az rest --resource "$DATABRICKS_RESOURCE" "$@"
}

ADMINS_GROUP_ID=$(dbx_rest --method get --url "$SCIM/Groups?filter=displayName%20eq%20admins" \
  --query "Resources[0].id" -o tsv)
DBX_SP_ID=$(dbx_rest --method get \
  --url "$SCIM/ServicePrincipals?filter=applicationId%20eq%20$APP_ID" \
  --query "Resources[0].id" -o tsv)
if [[ -z "$DBX_SP_ID" ]]; then
  DBX_SP_ID=$(dbx_rest --method post --url "$SCIM/ServicePrincipals" --body "$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"],
  "applicationId": "$APP_ID",
  "displayName": "$SP_NAME"
}
JSON
)" --query id -o tsv)
  echo "    added $SP_NAME to the workspace"
else
  echo "    $SP_NAME already in the workspace"
fi
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
echo "Subscription:      $SUBSCRIPTION_ID"
echo "Tenant:             $TENANT_ID"
echo "GitHub variables set on ${GITHUB_OWNER}/${REPO}: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, TFSTATE_RESOURCE_GROUP, TFSTATE_STORAGE_ACCOUNT"
