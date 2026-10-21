# Contract §2 / §7.3. The connection code carries identifiers only, never a secret.
# Disabled modules are null. jsonencode() produces compact JSON with sorted keys.

locals {
  connection = {
    v            = 1
    org          = var.symbol_org_id
    session      = var.setup_session_id
    template     = var.template_version
    tenancy      = var.tenancy_ocid
    home_region  = local.home_region
    realm        = local.realm
    stack_region = var.region
    modules      = local.enabled_modules

    signin = var.enable_signin ? {
      domain_url  = module.signin[0].domain_url
      domain_id   = module.signin[0].domain_id
      client_id   = module.signin[0].client_id
      ipt_id      = module.signin[0].ipt_id
      auth_method = module.signin[0].auth_method
    } : null

    finops = var.enable_finops ? {
      user        = module.finops[0].user_ocid
      fingerprint = module.finops[0].fingerprint
    } : null

    observability = local.needs_observability ? {
      user        = module.observability[0].user_ocid
      fingerprint = module.observability[0].fingerprint
    } : null

    monitoring = var.enable_monitoring ? {
      stream_ocid                  = module.monitoring[0].stream_ocid
      messages_endpoint            = module.monitoring[0].messages_endpoint
      stream_region                = module.monitoring[0].stream_region
      compartment_id               = module.monitoring[0].compartment_id
      cloud_guard_status           = module.monitoring[0].cloud_guard_status
      cloud_guard_reporting_region = module.monitoring[0].cloud_guard_reporting_region
    } : null

    security = var.enable_security ? {
      scan_compartment_id = local.scan_compartment
    } : null
  }

  # Unpadded base64url (RFC 4648 §5): '+' -> '-', '/' -> '_', drop the '=' padding.
  connection_b64url = replace(replace(replace(base64encode(jsonencode(local.connection)), "+", "-"), "/", "_"), "/=+$/", "")
  connection_code   = "SYMBOL-OCI-1.${local.connection_b64url}"
}

output "symbol_connection_code" {
  description = "Paste this code into Symbol (Administration > Cloud configuration > OCI). It contains identifiers only, no secret."
  value       = local.connection_code

  precondition {
    condition     = length(local.connection_code) <= 8192
    error_message = "The connection code exceeds 8192 characters (contract §1)."
  }
}

output "symbol_connection_summary" {
  description = "Human-readable summary of what this stack configured."
  value       = <<-EOT
    Symbol Cloud Connect ${var.template_version}
    Tenancy ${var.tenancy_ocid} (realm ${local.realm}), home region ${local.home_region}, stack region ${var.region}
    Modules: ${join(", ", local.enabled_modules)}
    %{~if var.enable_signin}
    %{~if module.signin[0].reused_existing}
    Sign-in: REUSED the existing trust "${module.signin[0].trust_name}" and its application (client id ${module.signin[0].client_id}) in ${module.signin[0].domain_url}. Nothing was created for sign-in, and Destroy will not remove them.
    %{~else}
    Sign-in: app "Symbol Integration" (client id ${module.signin[0].client_id}) and trust "Symbol-Trust" in ${module.signin[0].domain_url}, auth ${var.signin_auth_method}.
    %{~endif}
    %{~if var.signin_auth_method == "CLIENT_SECRET"}
      Client secret: NOT in the outputs by design. Copy it from Identity & Security > Domains > (your domain) > Integrated applications > (the application with client id ${module.signin[0].client_id}) > OAuth configuration, and paste it into Symbol together with the code.
    %{~endif}
    %{~endif}
    %{~if var.enable_finops}
    FinOps: user symbol-finops (key ${module.finops[0].fingerprint}), group symbol-finops, policy symbol-finops-policy.
    %{~endif}
    %{~if local.needs_observability}
    Observability: user symbol-observability (key ${module.observability[0].fingerprint}), group symbol-observability, policy symbol-observability-policy.
    %{~endif}
    %{~if var.enable_monitoring}
    Monitoring: stream symbol-monitoring-stream in ${module.monitoring[0].stream_region}, rule symbol-monitoring-rule, policy symbol-events-policy.
      Cloud Guard: ${module.monitoring[0].cloud_guard_status}, reporting region ${coalesce(module.monitoring[0].cloud_guard_reporting_region, "n/a")}${module.monitoring[0].cloud_guard_managed_by_symbol ? " (enabled by this stack)" : " (left unchanged)"}.
    %{~endif}
    %{~if var.enable_security}
    Security scan scope: ${local.scan_compartment == null ? "whole tenancy" : local.scan_compartment}.
    %{~endif}
    Service identities only work from Symbol's IPs (network source "symbol"). To revoke everything: Resource Manager > this stack > Edit > tick "Prepare removal" > Apply, then Destroy (OCI does not delete an active application).
  EOT
}
