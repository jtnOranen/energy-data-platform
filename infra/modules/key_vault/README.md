# key_vault

Key Vault with RBAC authorization (no access policies). Soft delete is 7 days and purge
protection is off -- acceptable for `dev`, where the vault may need to be destroyed and
recreated; revisit purge protection before a production environment exists. Role
assignments (who can read/write secrets) are the caller's responsibility, not this module's.
