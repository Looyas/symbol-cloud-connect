# Offline tests with mocked providers (no OCI account needed).
# Requires Terraform >= 1.7 (mock providers); Resource Manager (Terraform 1.5) ignores
# *.tftest.hcl files and scripts/package.sh does not ship them.
#   terraform init -backend=false && terraform test

mock_provider "oci" {
  alias = "mock"

  mock_data "oci_identity_region_subscriptions" {
    defaults = {
      region_subscriptions = [{
        is_home_region = true
        region_key     = "FRA"
        region_name    = "eu-frankfurt-1"
        state          = "READY"
        tenancy_id     = "ocid1.tenancy.oc1..aaaaaaaatest"
      }]
    }
  }

  mock_data "oci_identity_domains" {
    defaults = {
      domains = [
        {
          admin_email        = null, admin_first_name = null, admin_last_name = null, admin_user_name = null
          compartment_id     = "ocid1.tenancy.oc1..aaaaaaaatest", defined_tags = {}, description = "secondary"
          display_name       = "Users", freeform_tags = {}, home_region = "eu-frankfurt-1"
          home_region_url    = "https://idcs-0123456789abcdef0123456789abcdef.identity.oraclecloud.com:443", id = "ocid1.domain.oc1..users"
          is_hidden_on_login = false, is_notification_bypassed = false, is_primary_email_required = true
          license_type       = "free", lifecycle_details = null, replica_regions = [], state = "ACTIVE"
          time_created       = "2024-01-01T00:00:00Z", type = "SECONDARY", url = "https://idcs-0123456789abcdef0123456789abcdef.identity.oraclecloud.com:443"
        },
        {
          admin_email        = null, admin_first_name = null, admin_last_name = null, admin_user_name = null
          compartment_id     = "ocid1.tenancy.oc1..aaaaaaaatest", defined_tags = {}, description = "default"
          display_name       = "Default", freeform_tags = {}, home_region = "eu-frankfurt-1"
          home_region_url    = "https://idcs-fedcba9876543210fedcba9876543210.identity.oraclecloud.com:443", id = "ocid1.domain.oc1..default"
          is_hidden_on_login = false, is_notification_bypassed = false, is_primary_email_required = true
          license_type       = "free", lifecycle_details = null, replica_regions = [], state = "ACTIVE"
          time_created       = "2024-01-01T00:00:00Z", type = "DEFAULT", url = "https://idcs-fedcba9876543210fedcba9876543210.identity.oraclecloud.com:443"
        },
      ]
    }
  }

  mock_data "oci_identity_domain" {
    defaults = {
      url = "https://idcs-0123456789abcdef0123456789abcdef.identity.oraclecloud.com:443"
    }
  }

  # Cloud Guard already enabled by the customer in another region: must be left alone.
  mock_data "oci_cloud_guard_cloud_guard_configuration" {
    defaults = {
      status                = "ENABLED"
      reporting_region      = "eu-amsterdam-1"
      self_manage_resources = false
    }
  }

  mock_resource "oci_identity_domains_api_key" {
    defaults = {
      fingerprint = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
    }
  }

  mock_resource "oci_identity_domains_user" {
    defaults = {
      ocid = "ocid1.user.oc1..aaaaaaaamockuser"
    }
  }

  mock_resource "oci_identity_domains_app" {
    defaults = {
      name = "0123456789abcdef0123456789abcdef"
    }
  }

  mock_resource "oci_streaming_stream" {
    defaults = {
      # The stream lives in the stack's region (eu-amsterdam-1 below); OCI's messages
      # endpoint is always in the stream's own region, and connections-service rejects a
      # code where the two disagree.
      id                = "ocid1.stream.oc1.eu-amsterdam-1.aaaaaaaamock"
      messages_endpoint = "https://cell-1.streaming.eu-amsterdam-1.oci.oraclecloud.com"
    }
  }
}

mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtest\n-----END PUBLIC KEY-----\n"
    }
  }
}

override_data {
  target = data.http.ipt_certificate[0]
  values = {
    status_code   = 200
    response_body = "-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIE\nAbCd/+==\n-----END CERTIFICATE-----\n"
  }
}

variables {
  tenancy_ocid = "ocid1.tenancy.oc1..aaaaaaaatest"
  # The stack runs outside the home region (eu-frankfurt-1), in the reporting region of the
  # customer's existing Cloud Guard (see the mock above).
  region                       = "eu-amsterdam-1"
  symbol_org_id                = "org_123"
  setup_session_id             = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  symbol_ipt_certificate_url   = "https://platform.example.com/.well-known/symbol/oci/ipt-cert.pem"
  finops_public_key_url        = "https://platform.example.com/keys/finops.pem"
  observability_public_key_url = "https://platform.example.com/keys/observability.pem"
  symbol_egress_cidrs          = ["203.0.113.10/32", "198.51.100.0/28"]
  identity_domain_id           = "ocid1.domain.oc1..users"
  enable_signin                = true
  enable_finops                = true
  enable_monitoring            = true
  enable_security              = true
}

run "all_modules" {
  command = apply

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  assert {
    condition     = startswith(output.symbol_connection_code, "SYMBOL-OCI-1.") && !strcontains(output.symbol_connection_code, "=")
    error_message = "Connection code must start with SYMBOL-OCI-1. and be unpadded."
  }

  assert {
    condition     = !can(regex("[+/]", trimprefix(output.symbol_connection_code, "SYMBOL-OCI-1.")))
    error_message = "Connection code must be base64url (no '+' or '/')."
  }

  assert {
    condition     = local.connection.modules == ["signin", "finops", "monitoring", "security"]
    error_message = "modules must list the enabled modules in canonical order."
  }

  assert {
    condition     = local.connection.home_region == "eu-frankfurt-1" && local.connection.realm == "oc1" && local.connection.stack_region == "eu-amsterdam-1" && local.connection.monitoring.stream_region == "eu-amsterdam-1"
    error_message = "home_region / stack_region / realm detection is wrong."
  }

  assert {
    condition     = local.connection.signin.domain_url == "https://idcs-0123456789abcdef0123456789abcdef.identity.oraclecloud.com"
    error_message = "domain_url must be the canonical URL without :443."
  }

  assert {
    condition     = local.connection.signin.client_id == "0123456789abcdef0123456789abcdef" && local.connection.signin.auth_method == "CLIENT_SECRET"
    error_message = "signin block is wrong."
  }

  assert {
    condition     = local.default_domain_url == "https://idcs-fedcba9876543210fedcba9876543210.identity.oraclecloud.com:443"
    error_message = "Service identities must go to the Default domain."
  }

  assert {
    condition     = local.ipt_certificate_b64 == "MIIDdzCCAl+gAwIBAgIEAbCd/+=="
    error_message = "IPT certificate must be the base64 DER body."
  }

  assert {
    condition     = local.connection.monitoring.cloud_guard_status == "ENABLED" && local.connection.monitoring.cloud_guard_reporting_region == "eu-amsterdam-1"
    error_message = "Existing Cloud Guard must be reported unchanged."
  }

  assert {
    condition     = module.monitoring[0].cloud_guard_managed_by_symbol == false
    error_message = "An already-enabled Cloud Guard must never be taken over."
  }

  assert {
    condition     = local.connection.security.scan_compartment_id == null && local.connection.finops.fingerprint == "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
    error_message = "security / finops blocks are wrong."
  }

  assert {
    condition     = alltrue([for s in module.finops[0].policy_statements : strcontains(s, "where request.networkSource.name='symbol'") if startswith(s, "allow ")])
    error_message = "Every FinOps allow statement must carry the network-source condition."
  }

  assert {
    condition     = alltrue([for s in module.observability[0].policy_statements : endswith(s, "where request.networkSource.name='symbol'")])
    error_message = "Every observability statement must carry the network-source condition."
  }

  assert {
    condition     = length(module.observability[0].policy_statements) == 17
    error_message = "Observability policy must have 2 monitoring + 16 security statements, deduplicated (read cloud-guard-family once)."
  }
}

run "finops_only" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    enable_signin     = false
    enable_monitoring = false
    enable_security   = false
  }

  assert {
    condition     = local.connection.modules == ["finops"] && local.connection.signin == null && local.connection.observability == null && local.connection.monitoring == null && local.connection.security == null
    error_message = "Disabled modules must be null."
  }

  assert {
    condition     = length(data.http.ipt_certificate) == 0 && length(data.http.observability_public_key) == 0
    error_message = "Nothing must be fetched for disabled modules."
  }
}

run "no_module_fails" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    enable_signin     = false
    enable_finops     = false
    enable_monitoring = false
    enable_security   = false
  }

  expect_failures = [terraform_data.preflight]
}

run "signin_requires_domain" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    identity_domain_id = ""
  }

  expect_failures = [terraform_data.preflight]
}

run "empty_egress_fails" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    symbol_egress_cidrs = []
  }

  expect_failures = [terraform_data.preflight]
}

run "bad_cidr_rejected" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    symbol_egress_cidrs = ["203.0.113.10"]
  }

  expect_failures = [var.symbol_egress_cidrs]
}

run "cloud_guard_disabled_is_enabled_in_home_region" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    region = "eu-frankfurt-1"
  }


  override_data {
    target = module.monitoring[0].data.oci_cloud_guard_cloud_guard_configuration.current
    values = {
      status           = "DISABLED"
      reporting_region = null
    }
  }

  assert {
    condition     = module.monitoring[0].cloud_guard_managed_by_symbol
    error_message = "A disabled Cloud Guard must be enabled (create_cloud_guard = auto)."
  }

  assert {
    condition     = module.monitoring[0].cloud_guard_reporting_region == "eu-frankfurt-1"
    error_message = "Cloud Guard enabled by the stack must report in the home region."
  }
}

run "cloud_guard_never" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    region             = "eu-frankfurt-1"
    create_cloud_guard = "never"
  }

  override_data {
    target = module.monitoring[0].data.oci_cloud_guard_cloud_guard_configuration.current
    values = {
      status           = "DISABLED"
      reporting_region = null
    }
  }

  assert {
    condition     = !module.monitoring[0].cloud_guard_managed_by_symbol && module.monitoring[0].cloud_guard_status == "DISABLED"
    error_message = "create_cloud_guard = never must not touch Cloud Guard."
  }

  # Warning only: Cloud Guard stays disabled.
  expect_failures = [check.cloud_guard_enabled]
}

run "client_assertion" {
  command = plan

  providers = {
    oci      = oci.mock
    oci.home = oci.mock
    http     = http
  }

  variables {
    enable_finops          = false
    enable_monitoring      = false
    enable_security        = false
    signin_auth_method     = "CLIENT_ASSERTION"
    symbol_client_cert_pem = "-----BEGIN CERTIFICATE-----\nMIIBclientcert==\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = module.signin[0].auth_method == "CLIENT_ASSERTION" && local.use_client_assertion && length(data.http.client_certificate) == 0
    error_message = "CLIENT_ASSERTION with an inline certificate must not download anything."
  }

  assert {
    condition     = local.client_certificate_b64 == "MIIBclientcert=="
    error_message = "Client certificate must be passed as base64 DER."
  }
}
