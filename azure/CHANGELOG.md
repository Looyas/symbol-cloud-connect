# Changelog — `azure/`

All notable changes to the Azure template. Versions are `azure-vMAJOR.MINOR.PATCH` and a
release is immutable: a published tag is never moved, and the registry pins its commit.

## [azure-v1.0.1] — 2026-11-10

### Fixed

- **The storage account could not finish being created.** `shared_access_key_enabled =
  false` meant the azurerm provider's post-create blob data-plane poll — which uses the
  account key — got `403 KeyBasedAuthenticationNotPermitted`, failing the apply after 21
  of 23 resources and orphaning the account. Keys are enabled, with the reason recorded
  beside the setting and in [SECURITY.md](SECURITY.md). Symbol still reads the container
  with an Entra token as `Symbol Finops`; nothing uses a key.

## [azure-v1.0.0] — 2026-11-10

First release. Connects one Azure subscription: sign-in, FinOps, Monitoring and Security
posture.

### Added

- **Two Entra ID applications** in the customer's directory, `Symbol Finops` and
  `Symbol Observability`, each with one client secret Microsoft generates, owned by the
  administrator who ran the setup. Neither holds a Microsoft Graph permission.
- **FinOps**: storage account, container and a FOCUS 1.0 Cost Management export
  (`Microsoft.CostManagement/exports@2025-03-01` through `azapi`, since `azurerm` models
  only ActualCost and AmortizedCost exports). `--existing-export` reads one you already run.
- **Monitoring**: Event Hubs namespace (Standard — Basic allows only `$Default`), hub,
  the dedicated consumer group `symbol-monitoring`, and a subscription diagnostic setting
  `symbol-activity-log` streaming the Administrative, Security and Policy categories.
  `--existing-eventhub` reuses a namespace you already run; the consumer group is created
  either way.
- **Security**: `Reader`, `Security Reader` and `Monitoring Reader` on the subscription.
  Microsoft Defender for Cloud is read where already enabled and **never** turned on.
- **Sign-in**: creates nothing. The directory id travels in the connection code; a Global
  Administrator grants admin consent to Symbol's own application afterwards.
- `symbol-setup.sh`: checks the directory's app-registration policy before creating
  anything, registers the resource providers, bootstraps a private versioned state storage
  account in the customer's subscription, plans, confirms, applies, and prints the
  connection code once.
- `--rotate finops|observability` replaces one client secret; an ordinary re-run keeps
  both.
- `--destroy` removes everything the template created.

### Notes

- The connection code is **SECRET**: it carries both client secrets. See
  [SECURITY.md](SECURITY.md).
- The Terraform state contains those secrets, which is why the script keeps it in a
  private, versioned storage account in the customer's own subscription.
- This folder is Terraform rather than Bicep because an Entra application is a Microsoft
  Graph object and ARM cannot create one — see [README.md](README.md).
