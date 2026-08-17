# Azure Automation Variables

The runbooks use Azure Automation Variables for environment-specific configuration.

## Common variables

| Variable | Example | Purpose |
|---|---|---|
| `CitrixMediaPath` | `C:\source\Citrix_Virtual_Apps_and_Desktops_7_2507_LTSR_CU1` | Root of Citrix installation media on the target server |
| `KeyVaultName` | `ALPHAQ-KV` | Azure Key Vault containing the automation credential |
| `CitrixCredentialSecretName` | `citrix-automation-credential` | Key Vault secret containing the WinRM credential |
| `ValidationComputerName` | `ALFAQMGTDC01.alphaq.com` | Target used by validation/connectivity runbooks |

## Component variables

| Variable | Example | Used by |
|---|---|---|
| `LicenseServerComputerName` | `OP40ACTXDC002VM.op4.hos` | License Server and licensing runbooks |
| `DDCComputerName` | `ALFAQMGTDC01.alphaq.com` | DDC runbooks |
| `VDAComputerName` | `ALPHAQVDA01.alphaq.com` | VDA runbook |
| `CitrixLicensePort` | `27000` | Licensing configuration |

## Recommended initial variable set

```text
CitrixMediaPath
KeyVaultName
CitrixCredentialSecretName
LicenseServerComputerName
DDCComputerName
VDAComputerName
ValidationComputerName
CitrixLicensePort
```

## Security

Do not store passwords in Automation Variables. Passwords belong in Key Vault.

The Automation Account managed identity must have permission to read the required Key Vault secret.
