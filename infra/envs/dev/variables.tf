variable "location" {
  description = "Azure region for all dev resources."
  type        = string
  default     = "swedencentral"
}

variable "owner" {
  description = "Owner's Entra ID user principal name (email): the owner tag and the owner's Unity Catalog principal."
  type        = string
}

variable "owner_object_id" {
  description = "Azure AD object ID of the human owner. Granted Key Vault Secrets Officer on the dev vault so they can add API keys in phase 1."
  type        = string
  sensitive   = true # repo is public; keep this out of plan output and PR comments
}

variable "budget_amount_eur" {
  description = "Monthly consumption budget amount in EUR for the dev resource group."
  type        = number
  default     = 20
}

variable "alert_email" {
  description = "Email address notified when the budget threshold is crossed."
  type        = string
  sensitive   = true # repo is public; keep this out of plan output and PR comments
}
