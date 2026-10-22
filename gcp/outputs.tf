# Contract v2 §5.7, code version 2 (gcp-v2): the connection code carries the identifiers
# Symbol registers AND the key file of each service account. It is SECRET: the output is
# sensitive, symbol-setup.sh prints it once, and Symbol moves the keys to its Vault and
# keeps only the identifiers.
# Disabled modules (and identities a module set does not need) are null.
# jsonencode() produces compact JSON with sorted keys.

locals {
  keys = try(module.identity[0].keys, {})

  connection = {
    v               = 2
    org             = var.symbol_org_id
    session         = var.setup_session_id
    template        = var.template_version
    project         = var.project_id
    project_number  = tostring(data.google_project.this.number)
    organization_id = var.organization_id
    scope = {
      type = var.scope_type
      id   = local.scope_id
    }
    modules = local.enabled_modules

    key = {
      finops        = local.needs_finops_identity ? local.keys["finops"] : null
      observability = local.needs_observability_identity ? local.keys["observability"] : null
    }

    finops = var.enable_finops ? {
      project_id              = var.project_id
      dataset                 = module.finops[0].dataset_id
      table                   = module.finops[0].table_id
      billing_account_id      = var.billing_account_id == "" ? null : var.billing_account_id
      billing_export_detected = var.billing_export_detected
      focus_view_created      = module.finops[0].focus_view_created
    } : null

    observability = local.needs_observability_identity ? {
      project_id          = var.project_id
      subscription_id     = var.enable_monitoring ? module.monitoring[0].subscription_id : null
      scc_subscription_id = var.enable_monitoring ? module.monitoring[0].scc_subscription_id : null
      audit_scope_type    = var.scope_type
      audit_scope_id      = local.scope_id
    } : null
  }

  # Unpadded base64url (RFC 4648 §5): '+' -> '-', '/' -> '_', drop the '=' padding.
  connection_b64url = replace(replace(replace(base64encode(jsonencode(local.connection)), "+", "-"), "/", "_"), "/=+$/", "")
  connection_code   = "SYMBOL-GCP-2.${local.connection_b64url}"
}

output "symbol_connection_code" {
  description = "SECRET. Paste this code into Symbol (Administration > Cloud configuration > GCP) and nowhere else: it contains the keys of symbol-finops / symbol-observability. Print it with: terraform output -raw symbol_connection_code"
  value       = local.connection_code
  sensitive   = true

  precondition {
    # Two key files make the code about 8 KB; Symbol's decoder accepts up to 16384.
    condition     = nonsensitive(length(local.connection_code)) <= 16384
    error_message = "The connection code exceeds 16384 characters (Symbol's decoder limit for GCP codes)."
  }
}

output "symbol_connection_summary" {
  description = "Human-readable summary of what this template configured (no secret)."
  value       = <<-EOT
    Symbol Cloud Connect ${var.template_version}
    Project ${var.project_id} (number ${data.google_project.this.number})${var.organization_id == "" ? ", no organisation" : ", organisation ${var.organization_id}"}
    Scope: ${var.scope_type} ${local.scope_id}
    Modules: ${join(", ", local.enabled_modules)}
    %{~if local.needs_finops_identity}
    FinOps identity: ${coalesce(local.finops_email, "n/a")} (key ${coalesce(module.identity[0].finops_key_id, "n/a")})
    %{~endif}
    %{~if local.needs_observability_identity}
    Observability identity: ${coalesce(local.observability_email, "n/a")} (key ${coalesce(module.identity[0].observability_key_id, "n/a")})
    %{~endif}
    %{~if module.key_policy.exception_created}
    Key-creation policy exception: projects/${var.project_id} (removed by --destroy)
    %{~endif}
    %{~if var.enable_finops}
    FinOps: dataset ${var.project_id}.${module.finops[0].dataset_id}, table ${module.finops[0].table_id}${module.finops[0].focus_view_created ? " (FOCUS view managed by this template)" : ""}, billing account ${var.billing_account_id == "" ? "unknown" : var.billing_account_id}.
    %{~if !var.billing_export_detected}
      WARNING: the detailed billing export was not found. Enable it, then run symbol-setup.sh again.
    %{~endif}
    %{~endif}
    %{~if var.enable_monitoring}
    Monitoring: sink symbol-audit-sink (${var.scope_type}) -> topic symbol-monitoring -> ${module.monitoring[0].subscription_id}${var.enable_scc ? ", SCC findings -> ${module.monitoring[0].scc_subscription_id}" : ""}.
    %{~endif}
    %{~if var.enable_security}
    Security: roles/viewer, roles/iam.securityReviewer, roles/cloudasset.viewer, roles/storage.bucketViewer at ${var.scope_type} ${local.scope_id}.
    %{~endif}
    To rotate a key: run the Symbol rotation command (symbol-setup.sh --rotate finops|observability).
    To revoke everything: symbol-setup.sh --destroy --org ${var.symbol_org_id} --project ${var.project_id}
  EOT
}
