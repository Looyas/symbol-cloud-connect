###############################################################################
# Preflight: cross-variable and fetched-content checks.
# Preconditions are evaluated during Plan (values here are known at plan time), so a
# misconfigured stack fails before anything is created. They are not evaluated by
# Destroy, which must always work (it is how a customer revokes Symbol).
###############################################################################

resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition     = !var.enable_signin || try(module.signin[0].reuse_problem, "") == ""
      error_message = try(module.signin[0].reuse_problem, "")
    }
    precondition {
      condition     = length(local.enabled_modules) > 0
      error_message = "No module is enabled. Set at least one of enable_signin, enable_finops, enable_monitoring, enable_security (the Symbol link sets them for you)."
    }

    precondition {
      condition     = !var.enable_signin || var.identity_domain_id != ""
      error_message = "Sign-in is enabled: pick the identity domain your users sign in with (identity_domain_id)."
    }

    precondition {
      condition     = !var.enable_signin || local.ipt_certificate_b64 != ""
      error_message = "Sign-in is enabled but Symbol's IPT certificate could not be obtained (HTTP status: ${coalesce(local.fetch_status.ipt_certificate, "not fetched")}). Set symbol_ipt_certificate_url or paste symbol_ipt_certificate_pem."
    }

    precondition {
      condition     = !local.use_client_assertion || local.client_certificate_b64 != ""
      error_message = "signin_auth_method is CLIENT_ASSERTION but Symbol's client certificate could not be obtained (HTTP status: ${coalesce(local.fetch_status.client_certificate, "not fetched")}). Set symbol_client_cert_url or paste symbol_client_cert_pem."
    }

    precondition {
      condition     = !var.enable_finops || can(regex("^-----BEGIN PUBLIC KEY-----[A-Za-z0-9+/=\\s]+-----END PUBLIC KEY-----$", local.finops_public_key_pem))
      error_message = "FinOps is enabled but the symbol-finops public key could not be obtained (HTTP status: ${coalesce(local.fetch_status.finops_public_key, "not fetched")}). Setup links expire after 24 hours: start a new setup in Symbol to get a fresh link."
    }

    precondition {
      condition     = !local.needs_observability || can(regex("^-----BEGIN PUBLIC KEY-----[A-Za-z0-9+/=\\s]+-----END PUBLIC KEY-----$", local.observability_public_key_pem))
      error_message = "Monitoring or Security is enabled but the symbol-observability public key could not be obtained (HTTP status: ${coalesce(local.fetch_status.observability_public_key, "not fetched")}). Setup links expire after 24 hours: start a new setup in Symbol to get a fresh link."
    }

    precondition {
      condition     = !local.needs_service_identity || length(var.symbol_egress_cidrs) > 0
      error_message = "symbol_egress_cidrs is empty. Symbol's service identities are restricted to Symbol's egress IPs and cannot be created without them."
    }

    precondition {
      condition     = !local.needs_service_identity || local.default_domain_url != ""
      error_message = "Could not find the tenancy's ACTIVE Default identity domain, where the Symbol service users are created."
    }

    precondition {
      # The usage-report tenancy OCID in the FinOps policy is the oc1 (commercial realm) one.
      condition     = !var.enable_finops || local.realm == local.usage_report_realm_oc1
      error_message = "FinOps is only supported in the commercial realm (oc1); this tenancy is in realm ${local.realm}."
    }
  }
}

###############################################################################
# Modules. Order of creation follows plan §4.4; every IAM / identity write goes through
# the home-region provider.
# No module-level depends_on on the preflight: it would defer every data source in the
# modules (Cloud Guard status, identity domain) to apply time and break count decisions.
# A failing precondition already stops the run at plan time.
###############################################################################

module "network" {
  source    = "./modules/network"
  count     = local.needs_service_identity ? 1 : 0
  providers = { oci = oci.home }

  tenancy_ocid  = var.tenancy_ocid
  egress_cidrs  = var.symbol_egress_cidrs
  freeform_tags = local.freeform_tags
}

module "finops" {
  source    = "./modules/finops"
  count     = var.enable_finops ? 1 : 0
  providers = { oci = oci.home }

  tenancy_ocid              = var.tenancy_ocid
  idcs_endpoint             = local.default_domain_url
  public_key_pem            = local.finops_public_key_pem
  network_source_name       = module.network[0].name
  service_user_email_domain = var.service_user_email_domain
  freeform_tags             = local.freeform_tags
}

module "observability" {
  source    = "./modules/observability"
  count     = local.needs_observability ? 1 : 0
  providers = { oci = oci.home }

  tenancy_ocid              = var.tenancy_ocid
  idcs_endpoint             = local.default_domain_url
  public_key_pem            = local.observability_public_key_pem
  network_source_name       = module.network[0].name
  enable_monitoring         = var.enable_monitoring
  enable_security           = var.enable_security
  monitoring_compartment_id = local.monitoring_compartment
  scan_compartment_id       = local.scan_compartment
  service_user_email_domain = var.service_user_email_domain
  freeform_tags             = local.freeform_tags
}

module "monitoring" {
  source = "./modules/monitoring"
  count  = var.enable_monitoring ? 1 : 0
  providers = {
    oci      = oci
    oci.home = oci.home
  }

  tenancy_ocid       = var.tenancy_ocid
  region             = var.region
  home_region        = local.home_region
  compartment_id     = local.monitoring_compartment
  extra_event_types  = var.extra_event_types
  create_cloud_guard = var.create_cloud_guard
  freeform_tags      = local.freeform_tags
}

module "signin" {
  source    = "./modules/signin"
  count     = var.enable_signin ? 1 : 0
  providers = { oci = oci.home }

  identity_domain_id     = var.identity_domain_id
  redirect_uri           = var.redirect_uri
  issuer                 = var.symbol_issuer
  ipt_certificate_b64    = local.ipt_certificate_b64
  auth_method            = var.signin_auth_method
  client_certificate_b64 = local.client_certificate_b64
  freeform_tags          = local.freeform_tags
  deactivate             = var.prepare_removal
}

###############################################################################
# Warnings (check blocks report in the plan/apply output but never block a run).
###############################################################################

check "cloud_guard_enabled" {
  assert {
    condition     = !var.enable_monitoring || try(module.monitoring[0].cloud_guard_status == "ENABLED", true)
    error_message = "Cloud Guard is not enabled and create_cloud_guard = never: no problem will reach the Symbol stream until Cloud Guard is enabled."
  }
}

check "cloud_guard_same_region" {
  assert {
    condition     = !var.enable_monitoring || try(module.monitoring[0].cloud_guard_reporting_region == null || module.monitoring[0].cloud_guard_reporting_region == var.region, true)
    error_message = "Cloud Guard reports in a region other than ${var.region}. Cloud Guard events are emitted in its reporting region: run this stack in that region so the Events rule and the stream are created there."
  }
}
