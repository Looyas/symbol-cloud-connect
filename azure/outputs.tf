# Contract v2 §6.7, code version 2 (azure-v1): the connection code carries the
# identifiers Symbol registers AND the client secret of each application. It is SECRET:
# the output is sensitive, symbol-setup.sh prints it once, and Symbol moves the secrets
# to its vault and keeps only the identifiers.
#
# Disabled modules (and identities a module set does not need) are null.
# jsonencode() produces compact JSON with sorted keys.

locals {
  credentials = try(module.identity[0].credentials, {})

  connection = {
    v        = 2
    org      = var.symbol_org_id
    session  = var.setup_session_id
    template = var.template_version
    modules  = local.enabled_modules

    # Both are top-level: `signin` needs the directory and nothing else, and the
    # subscription is what the integration binds to. Neither is repeated per module.
    tenant       = lower(var.tenant_id)
    subscription = lower(var.subscription_id)

    app = {
      finops        = local.needs_finops_identity ? local.credentials["finops"] : null
      observability = local.needs_observability_identity ? local.credentials["observability"] : null
    }

    finops = var.enable_finops ? {
      storage_account = local.export_storage_account
      container       = local.export_container_final
      directory       = local.export_directory_final
      export_name     = local.export_name_final
      export_created  = local.creates_export
    } : null

    observability = local.needs_observability_identity ? {
      # Null when the Monitoring module is off: a security-only connection is a
      # complete, correct connection with no event pipe at all, and "" on the row
      # would be a namespace the collector then tried to open.
      eventhub_namespace = var.enable_monitoring ? local.eventhub_namespace_final : null
      eventhub_name      = var.enable_monitoring ? local.eventhub_name_final : null
      consumer_group     = var.enable_monitoring ? local.consumer_group : null
      monitoring_enabled = var.enable_monitoring
      security_enabled   = var.enable_security
    } : null
  }

  # Unpadded base64url (RFC 4648 §5): '+' -> '-', '/' -> '_', drop the '=' padding.
  connection_b64url = replace(replace(replace(base64encode(jsonencode(local.connection)), "+", "-"), "/", "_"), "/=+$/", "")
  connection_code   = "SYMBOL-AZURE-2.${local.connection_b64url}"
}

output "symbol_connection_code" {
  description = "SECRET. Paste this code into Symbol (Administration > Cloud configuration > Azure) and nowhere else: it contains the client secrets of the Symbol applications. Print it with: terraform output -raw symbol_connection_code"
  value       = local.connection_code
  sensitive   = true

  precondition {
    # Two secrets make the code well under 4 KB; Symbol's decoder accepts up to 16384.
    condition     = nonsensitive(length(local.connection_code)) <= 16384
    error_message = "The connection code exceeds 16384 characters (Symbol's decoder limit for Azure codes)."
  }
}

# Read back by symbol-setup.sh on the next run. A plain re-run passes these values
# through unchanged, so every secret Symbol already holds survives it; only --rotate
# sets a new value, and only for the identity it names.
output "secret_rotation_ids" {
  description = "The rotation ids this apply used, per identity."
  value       = var.secret_rotation_ids
}

output "symbol_connection_summary" {
  description = "Human-readable summary of what this template configured (no secret)."
  value       = <<-EOT
    Symbol Cloud Connect ${var.template_version}
    Subscription ${var.subscription_id} in directory ${var.tenant_id}
    Modules: ${join(", ", local.enabled_modules)}
    %{~if local.needs_resource_group}
    Resource group: ${local.resource_group_name} (${var.location}) -- everything this template created lives here
    %{~endif}
    %{~if local.needs_finops_identity}
    FinOps identity: Symbol Finops (${var.symbol_org_id}), client ${coalesce(module.identity[0].finops_client_id, "n/a")}
    %{~endif}
    %{~if local.needs_observability_identity}
    Observability identity: Symbol Observability (${var.symbol_org_id}), client ${coalesce(module.identity[0].observability_client_id, "n/a")}
    %{~endif}
    Secrets expire in ${var.secret_valid_months} months. Symbol shows the date on the integration card.
    %{~if var.enable_signin}
    Sign-in: members sign in to directory ${var.tenant_id}. Nothing was created for it -- a directory administrator must still grant admin consent to Symbol's sign-in application, from the link Symbol shows.
    %{~endif}
    %{~if var.enable_finops}
    FinOps: FOCUS 1.0 export ${local.export_name_final} -> ${local.export_storage_account}/${local.export_container_final}/${local.export_directory_final}/${local.export_name_final}/${local.creates_export ? " (created by this template)" : " (your existing export)"}
      The first file appears within 24 hours. Symbol accepts the connection before then.
    %{~endif}
    %{~if local.creates_eventhub}
    Monitoring: Activity Log (Administrative, Security, Policy) -> ${local.eventhub_namespace_final}/${local.eventhub_name_final}, consumer group ${local.consumer_group} (created by this template)
    %{~endif}
    %{~if var.enable_monitoring && !local.creates_eventhub}
    Monitoring: Symbol reads ${local.eventhub_namespace_final}/${local.eventhub_name_final} through consumer group ${local.consumer_group} (your existing namespace). Your own diagnostic setting keeps routing the Activity Log there; Symbol checks it when the code is pasted.
    %{~endif}
    %{~if var.enable_security}
    Security: Reader, Security Reader and Monitoring Reader on the subscription. Defender for Cloud is READ where you have enabled it; this template never turns a paid plan on.
    %{~endif}
    To rotate a secret: symbol-setup.sh --rotate finops|observability
    To revoke everything: symbol-setup.sh --destroy --org ${var.symbol_org_id} --subscription ${var.subscription_id}
  EOT
}
