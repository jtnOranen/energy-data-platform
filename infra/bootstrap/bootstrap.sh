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

GITHUB_OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER, e.g. GITHUB_OWNER=jtnOranen ./bootstrap.sh}"
LOCATION="${LOCATION:-swedencentral}"

REPO="energy-data-platform"
RESOURCE_GROUP="rg-energy-tfstate"
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

SUBSCRIPTION_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
STORAGE_SCOPE=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

assign_role_if_missing "Contributor" "$SUBSCRIPTION_SCOPE"
assign_role_if_missing "Role Based Access Control Administrator" "$SUBSCRIPTION_SCOPE"
assign_role_if_missing "Storage Blob Data Contributor" "$STORAGE_SCOPE"

echo "==> GitHub repo variables (not secrets) on ${GITHUB_OWNER}/${REPO}"
gh variable set AZURE_CLIENT_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$APP_ID"
gh variable set AZURE_TENANT_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${REPO}" --body "$SUBSCRIPTION_ID"
gh variable set TFSTATE_RESOURCE_GROUP --repo "${GITHUB_OWNER}/${REPO}" --body "$RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --repo "${GITHUB_OWNER}/${REPO}" --body "$STORAGE_ACCOUNT"

echo ""
echo "==> Done"
echo "Resource group:    $RESOURCE_GROUP"
echo "Storage account:   $STORAGE_ACCOUNT"
echo "Blob container:    $CONTAINER_NAME"
echo "App registration:  $SP_NAME ($APP_ID)"
echo "Subscription:      $SUBSCRIPTION_ID"
echo "Tenant:             $TENANT_ID"
echo "GitHub variables set on ${GITHUB_OWNER}/${REPO}: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, TFSTATE_RESOURCE_GROUP, TFSTATE_STORAGE_ACCOUNT"
