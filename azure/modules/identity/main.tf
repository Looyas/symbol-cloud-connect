###############################################################################
# The identities Symbol signs in as (contract v2 §6.4).
#
# ONE APPLICATION PER CREDENTIAL SET, NOT ONE FOR BOTH
# ----------------------------------------------------
# `symbol-finops` reads a blob container and the cost APIs. `symbol-observability`
# reads the subscription, Defender and an Event Hub. They are separate applications
# for the reason the GCP template uses two service accounts: a single one would hold
# the union of both role sets, so a leak of the ingestion credential would also carry
# read access to every resource in the subscription. Symbol stores them in separate
# vault paths and rotates them independently.
#
# THE SECRET IS MICROSOFT'S, GENERATED HERE, AND LEAVES ONCE
# ----------------------------------------------------------
# `azuread_application_password` asks Entra for the value; Terraform never chooses it.
# It is marked sensitive all the way to the connection code, printed once by
# symbol-setup.sh, and moved into Symbol's vault the moment the code is accepted.
# It IS in this configuration's state file -- which is why symbol-setup.sh keeps the
# state in a private, versioned storage account in the customer's own subscription,
# and why SECURITY.md says so plainly rather than leaving it to be discovered.
###############################################################################

locals {
  identities = merge(
    var.needs_finops ? { finops = "FinOps (cost ingestion)" } : {},
    var.needs_observability ? { observability = "Monitoring and security posture" } : {},
  )
}

resource "azuread_application" "this" {
  for_each = local.identities

  display_name = "Symbol ${title(each.key)} (${var.symbol_org_id})"
  description  = "Read-only identity used by Symbol for ${each.value}. Created by Symbol Cloud Connect."

  # Single tenant: this application exists for this directory only and is never
  # consented to anywhere else.
  sign_in_audience = "AzureADMyOrg"

  # No API permissions at all. Everything Symbol reads is authorised by AZURE RBAC on
  # the subscription (modules/finops, monitoring, security), never by a Microsoft Graph
  # permission -- so this application needs no admin consent and can read nothing in
  # the directory itself.
  owners = [var.owner_object_id]

  lifecycle {
    # The display name carries the organisation; changing it would recreate the
    # application and invalidate the credential Symbol holds.
    ignore_changes = [owners]
  }
}

resource "azuread_service_principal" "this" {
  for_each = local.identities

  client_id = azuread_application.this[each.key].client_id
  owners    = [var.owner_object_id]

  # The identity is used by a service, never by a person signing in.
  account_enabled              = true
  app_role_assignment_required = false

  description = "Symbol ${each.key} -- read-only, role assignments only."

  lifecycle {
    ignore_changes = [owners]
  }
}

# An absolute expiry, pinned in state. `end_date_relative` would be recomputed on
# every plan and show a diff that is not a change.
resource "time_offset" "secret" {
  for_each = local.identities

  offset_days = var.secret_valid_months * 30

  triggers = {
    rotation = lookup(var.secret_rotation_ids, each.key, "initial")
  }
}

resource "azuread_application_password" "this" {
  for_each = local.identities

  application_id = azuread_application.this[each.key].id
  display_name   = "symbol-${each.key}"
  end_date       = time_offset.secret[each.key].rfc3339

  # Replaced ONLY when symbol-setup.sh --rotate changes this identity's value. An
  # ordinary re-run keeps the secret Symbol already holds: a template that minted a
  # new secret on every apply would cut its own access every time the customer
  # updated an option.
  rotate_when_changed = {
    rotation = lookup(var.secret_rotation_ids, each.key, "initial")
  }
}
