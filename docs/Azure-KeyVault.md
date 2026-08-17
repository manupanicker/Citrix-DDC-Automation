# Azure Key Vault

## Purpose

Key Vault centralizes the credential used by the runbooks when they connect to target Windows servers through WinRM.

## Secret

The Automation Variable `CitrixCredentialSecretName` identifies the secret.

Expected secret value:

```json
{
  "Username": "DOMAIN\\svc-citrixautomation",
  "Password": "<password>"
}
```

## Access model

```text
Azure Automation Account
        |
        | Managed Identity
        v
Azure Key Vault
        |
        | Secret read
        v
WinRM credential
        |
        v
Target Windows Server
```

## Required permissions

The Automation Account managed identity needs permission to read secrets from the Key Vault. Prefer the least-privilege Azure RBAC role appropriate for the vault, such as `Key Vault Secrets User` when using the Azure RBAC permission model.

Do not commit secret values, passwords, or exported credentials to GitHub.
