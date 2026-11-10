# Changelog — `azure/`

All notable changes to the Azure template. Versions are `azure-vMAJOR.MINOR.PATCH` and a
release is immutable: a published tag is never moved, and the registry pins its commit.

## [azure-v1.0.4] — 2026-11-10

### Fixed

- **The Event Hub did not follow its namespace.** Changing the region replaces the
  namespace, and a replaced namespace comes back empty — but the provider plans the hub
  as an in-place UPDATE, because `namespace_id` is only "known after apply" and nothing
  marks it as forcing replacement. The update then failed with `partition_count cannot
  be decreased`, and even where it would not have failed, Terraform was left believing
  in a hub that no longer existed. The hub's life is tied to the namespace's now.

### Confirmed working in a real subscription

- The **FOCUS 1.0 export** created in 11 seconds
  (`Microsoft.CostManagement/exports@2025-03-01`, `type: FocusCost`,
  `dataVersion: 1.0`) — the shape was right. The `401 RBACAccessDenied` of the first
  run was first-time registration of `Microsoft.CostManagement` not yet propagated,
  which the preflight added in v1.0.2 now also covers as a readiness probe.
- The **blob role assignment** completed in 35 seconds at account scope, where container
  scope had timed out after thirty minutes.

## [azure-v1.0.3] — 2026-11-10

### Fixed

- **`--destroy` could never have run**, in any released version. It carries no session
  and no release, and `variables.tf` validates both; `destroy_mode` bypasses the
  lifecycle preconditions only, so terraform refused the var file with
  "setup_session_id must be a UUID" before doing anything. Destroy now supplies values
  that satisfy the validation — they are not read, because a destroy removes whatever is
  in state.

  Found by a question, not a test: the revoke path only runs when something has already
  gone wrong, so nothing exercised it. `tests/test_code_schema.py` pins it now.

## [azure-v1.0.2] — 2026-11-10

Both came out of a real apply, not a review.

### Fixed

- **The blob role assignment never completed.** Scoped to the container, the provider
  created it and then polled for it to "finish replicating" for **thirty minutes**
  before timing out — while the subscription-scoped assignment beside it took 32
  seconds. It is scoped to the storage **account** now. Where the setup creates the
  account that costs nothing; with `--existing-export` it is wider, and
  [PERMISSIONS.md](PERMISSIONS.md) says so.

### Added

- **A Cost Management preflight.** `Microsoft.CostManagement` refused the export with
  `401 RBACAccessDenied` even though the admin was Owner: cost access is governed at the
  **billing account**, not the subscription, and nothing in this template can grant it.
  The script now checks before creating anything and names who can fix it — an EA
  administrator turning on 'AO view charges', or Cost Management Contributor on an MCA
  billing profile — and offers `--modules monitoring,security` as the way to proceed
  without FinOps.

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
