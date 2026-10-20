# resource_group_name, storage_account_name, container_name and key are supplied via
# -backend-config at init time (from the TFSTATE_RESOURCE_GROUP / TFSTATE_STORAGE_ACCOUNT
# repo variables that infra/bootstrap/bootstrap.sh writes), so no resource names are
# hard-coded here -- consistent with docs/conventions.md's "no hard-coded IDs" rule.
#
#   terraform init \
#     -backend-config="resource_group_name=$TFSTATE_RESOURCE_GROUP" \
#     -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
#     -backend-config="container_name=tfstate" \
#     -backend-config="key=dev.tfstate"
#
# use_oidc is what GitHub Actions authenticates with (see docs/adr/0004). Locally, with no
# OIDC token environment variables present, the azurerm backend falls back to your `az
# login` session instead.
terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}
