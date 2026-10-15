###############################################################################
# Home region detection.
# IAM is global but writes are only accepted in the home region, and Resource Manager
# may run the stack in any subscribed region. The home region feeds provider.oci.home.
###############################################################################

data "oci_identity_region_subscriptions" "home" {
  tenancy_id = var.tenancy_ocid

  filter {
    name   = "is_home_region"
    values = ["true"]
  }
}

locals {
  home_region = data.oci_identity_region_subscriptions.home.region_subscriptions[0].region_name

  # ocid1.tenancy.<realm>..<unique id>
  realm = split(".", var.tenancy_ocid)[2]

  # Contract §1: every resource carries these tags.
  freeform_tags = {
    "symbol-managed"  = "true"
    "symbol-org"      = var.symbol_org_id
    "symbol-template" = var.template_version
  }

  needs_observability     = var.enable_monitoring || var.enable_security
  needs_service_identity  = var.enable_finops || local.needs_observability
  monitoring_compartment  = var.monitoring_compartment_id != "" ? var.monitoring_compartment_id : var.tenancy_ocid
  scan_compartment        = var.scan_compartment_id != "" ? var.scan_compartment_id : null
  enabled_modules         = [for m in ["signin", "finops", "monitoring", "security"] : m if local.module_flags[m]]
  module_flags            = { signin = var.enable_signin, finops = var.enable_finops, monitoring = var.enable_monitoring, security = var.enable_security }
  use_client_assertion    = var.enable_signin && var.signin_auth_method == "CLIENT_ASSERTION"
  usage_report_realm_oc1  = "oc1"
  first_certificate_regex = "-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]+)-----END CERTIFICATE-----"
}

###############################################################################
# Public material published by Symbol.
# Inline *_pem inputs win; otherwise the PEM is downloaded from the public *_url.
# Content is validated by the preconditions in main.tf (not by data-source
# postconditions: those would also run during Destroy and could block a revocation once
# the setup session has expired and the URL returns 404).
###############################################################################

data "http" "ipt_certificate" {
  count = var.enable_signin && var.symbol_ipt_certificate_pem == "" && var.symbol_ipt_certificate_url != "" ? 1 : 0
  url   = var.symbol_ipt_certificate_url

  request_headers = { Accept = "application/x-pem-file" }

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }
}

data "http" "client_certificate" {
  count = local.use_client_assertion && var.symbol_client_cert_pem == "" && var.symbol_client_cert_url != "" ? 1 : 0
  url   = var.symbol_client_cert_url

  request_headers = { Accept = "application/x-pem-file" }

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }
}

data "http" "finops_public_key" {
  count = var.enable_finops && var.finops_public_key_pem == "" && var.finops_public_key_url != "" ? 1 : 0
  url   = var.finops_public_key_url

  request_headers = { Accept = "application/x-pem-file" }

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }
}

data "http" "observability_public_key" {
  count = local.needs_observability && var.observability_public_key_pem == "" && var.observability_public_key_url != "" ? 1 : 0
  url   = var.observability_public_key_url

  request_headers = { Accept = "application/x-pem-file" }

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }
}

locals {
  # HTTP status of each download (null when the inline PEM was used or nothing was fetched).
  fetch_status = {
    ipt_certificate          = try(data.http.ipt_certificate[0].status_code, null)
    client_certificate       = try(data.http.client_certificate[0].status_code, null)
    finops_public_key        = try(data.http.finops_public_key[0].status_code, null)
    observability_public_key = try(data.http.observability_public_key[0].status_code, null)
  }

  ipt_certificate_pem          = var.symbol_ipt_certificate_pem != "" ? var.symbol_ipt_certificate_pem : (local.fetch_status.ipt_certificate == 200 ? trimspace(data.http.ipt_certificate[0].response_body) : "")
  client_certificate_pem       = var.symbol_client_cert_pem != "" ? var.symbol_client_cert_pem : (local.fetch_status.client_certificate == 200 ? trimspace(data.http.client_certificate[0].response_body) : "")
  finops_public_key_pem        = var.finops_public_key_pem != "" ? trimspace(var.finops_public_key_pem) : (local.fetch_status.finops_public_key == 200 ? trimspace(data.http.finops_public_key[0].response_body) : "")
  observability_public_key_pem = var.observability_public_key_pem != "" ? trimspace(var.observability_public_key_pem) : (local.fetch_status.observability_public_key == 200 ? trimspace(data.http.observability_public_key[0].response_body) : "")

  # Identity domains expect certificates as the base64 DER body: the first PEM block,
  # without the BEGIN/END lines and without line breaks.
  ipt_certificate_b64    = try(replace(regex(local.first_certificate_regex, local.ipt_certificate_pem)[0], "/\\s+/", ""), "")
  client_certificate_b64 = try(replace(regex(local.first_certificate_regex, local.client_certificate_pem)[0], "/\\s+/", ""), "")
}

###############################################################################
# Default identity domain.
# The symbol-finops / symbol-observability service users and groups live in the
# tenancy's Default domain, whatever domain users sign in with. Policies can then name
# the groups without a domain prefix ("group symbol-finops"), exactly as documented in
# PERMISSIONS.md and in Symbol's manual guide.
###############################################################################

data "oci_identity_domains" "root" {
  provider       = oci.home
  count          = local.needs_service_identity ? 1 : 0
  compartment_id = var.tenancy_ocid
}

locals {
  default_domains = [
    for d in try(data.oci_identity_domains.root[0].domains, []) : d
    if upper(d.type) == "DEFAULT" && upper(d.state) == "ACTIVE"
  ]
  default_domain_url = try(local.default_domains[0].url, "")
}
