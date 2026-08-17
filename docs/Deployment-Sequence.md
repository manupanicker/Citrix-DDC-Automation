# Deployment Sequence

## Phase 1 - Windows infrastructure

1. Create the Azure VM.
2. Configure networking and DNS.
3. Domain-join the server.
4. Install required Windows prerequisites.
5. Ensure WinRM works from the Hybrid Worker.
6. Confirm the Azure Automation Hybrid Worker is healthy.

## Phase 2 - Citrix binaries

1. Install the Citrix License Server.
2. Install the Delivery Controller.
3. Reboot where the installer requires it.
4. Validate Citrix services.
5. Install the VDA on VDA targets.

## Phase 3 - Citrix configuration

Keep Site configuration separate from binary installation.

Typical configuration tasks include:

- Create the Citrix Site.
- Configure the Site database.
- Configure the Licensing server.
- Configure administrators.
- Create Delivery Groups and Machine Catalogs as required.

## Phase 4 - Validation

Run the validation runbook after each major phase.

The validation should verify:

- Windows connectivity.
- Citrix services.
- Expected installation directories.
- Required ports where applicable.
- Citrix SDK availability.
- Site/controller health after Site configuration.
