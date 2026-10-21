# User sign-in: the "Symbol Integration" confidential application and the "Symbol-Trust"
# Identity Propagation Trust, in the identity domain users sign in with (plan §4.4 rows
# 7-8). Users keep their own OCI permissions: Symbol creates no policy for them and the
# application has NO app role (in particular not Identity Domain Administrator).
#
# Docs: https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/identity_domains_app.html
#       https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/identity_domains_identity_propagation_trust.html
#       https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/identity_domains_oauth_client_certificate.html
#       https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/json_web_token_exchange.htm
#
# SECRET IN STATE: the provider exports the application's generated `client_secret` as a
# computed, non-sensitive attribute, so it is stored in the Resource Manager state (never
# in an output). See SECURITY.md.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.3.0"
    }
  }
}

variable "identity_domain_id" {
  type        = string
  description = "OCID of the identity domain users sign in with."
}

variable "redirect_uri" {
  type        = string
  description = "The single redirect URI allowed for the authorization-code flow."
}

variable "issuer" {
  type        = string
  description = "iss claim of Symbol broker JWTs."
}

variable "ipt_certificate_b64" {
  type        = string
  description = "Symbol IPT certificate, base64 DER (PEM body without header/footer/newlines)."
}

variable "auth_method" {
  type        = string
  description = "CLIENT_SECRET or CLIENT_ASSERTION."
}

variable "client_certificate_b64" {
  type        = string
  default     = ""
  description = "CLIENT_ASSERTION only: Symbol client certificate, base64 DER."
}

variable "deactivate" {
  type        = bool
  default     = false
  description = "Deactivate the app and the trust (step 1 of removal: OCI refuses to delete an active app)."
}

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags."
}

# Read only when a domain was picked. With an empty id the provider fails on the request
# itself ("can not marshal ... DomainId ... nil pointer") BEFORE the root precondition
# ("pick the identity domain ...") can report the real cause -- seen in Resource Manager
# when the form's domain dropdown is left empty.
data "oci_identity_domain" "this" {
  count     = var.identity_domain_id != "" ? 1 : 0
  domain_id = var.identity_domain_id
}

# An identity domain accepts ONE propagation trust per issuer: creating a second one for
# Symbol's issuer fails with "409 conflicted state" after the provider has retried for two
# minutes. Every domain set up with the earlier manual guide (PowerShell) already has one,
# together with its "Symbol Integration" app. Such a trust -- one this stack did not
# create -- is REUSED: the stack then creates neither the app nor the trust, and reports
# their ids in the connection code. A trust this stack created itself carries the marker
# below in its description and stays managed (re-applying an existing stack must not
# turn its own trust into a "foreign" one and destroy it).
data "oci_identity_domains_identity_propagation_trusts" "same_issuer" {
  count          = local.idcs_endpoint != "" ? 1 : 0
  idcs_endpoint  = local.idcs_endpoint
  attribute_sets = ["all"]
}

locals {
  idcs_endpoint    = try(data.oci_identity_domain.this[0].url, "")
  client_assertion = var.auth_method == "CLIENT_ASSERTION"
  # The domain URL is returned with an explicit :443; the connection code carries the
  # canonical form https://idcs-<id>.identity.oraclecloud.com (contract §2 / plan §4.5).
  domain_url = trimsuffix(trimsuffix(local.idcs_endpoint, "/"), ":443")
  # Domain-wide alias of the imported client certificate (CLIENT_ASSERTION only).
  certificate_alias = "symbol-integration-client"

  managed_marker = "Managed by the symbol-cloud-connect stack"
  foreign_trusts = [
    for t in try(data.oci_identity_domains_identity_propagation_trusts.same_issuer[0].identity_propagation_trusts, []) :
    # Filtered here, not with a SCIM filter on `issuer`: a domain holds only a handful
    # of trusts, and this does not depend on which attributes the API lets you filter on.
    t if t.issuer == var.issuer && !strcontains(t.description != null ? t.description : "", local.managed_marker)
  ]
  existing_trust = length(local.foreign_trusts) > 0 ? local.foreign_trusts[0] : null
  reuse          = local.existing_trust != null
  create         = !local.reuse

  existing_client_id = try(local.existing_trust.oauth_clients[0], "")
  # Base64 bodies compared without whitespace: the API may wrap the stored certificate.
  existing_cert_matches = local.reuse ? replace(try(local.existing_trust.public_certificate, ""), "/\\s/", "") == replace(var.ipt_certificate_b64, "/\\s/", "") : true
}

# The app the reused trust accepts, to check its redirect URI.
data "oci_identity_domains_apps" "existing" {
  count          = local.reuse && local.existing_client_id != "" ? 1 : 0
  idcs_endpoint  = local.idcs_endpoint
  app_filter     = "name eq \"${local.existing_client_id}\""
  attribute_sets = ["all"]
}

locals {
  existing_redirect_uris = try(data.oci_identity_domains_apps.existing[0].apps[0].redirect_uris, [])
}

# Earlier releases created these two without `count`; keep their state on upgrade.
moved {
  from = oci_identity_domains_app.symbol
  to   = oci_identity_domains_app.symbol[0]
}

moved {
  from = oci_identity_domains_identity_propagation_trust.symbol
  to   = oci_identity_domains_identity_propagation_trust.symbol[0]
}

# CLIENT_ASSERTION: the provider cannot upload certificate content on the application
# itself (certificates.x509base64certificate is read-only in the schema). The certificate
# is imported as an OAuth client certificate and referenced from the app by alias.
resource "oci_identity_domains_oauth_client_certificate" "symbol" {
  count                 = local.create && local.client_assertion ? 1 : 0
  idcs_endpoint         = local.idcs_endpoint
  schemas               = ["urn:ietf:params:scim:schemas:oracle:idcs:OAuthClientCertificate"]
  certificate_alias     = local.certificate_alias
  x509base64certificate = var.client_certificate_b64
}

resource "oci_identity_domains_app" "symbol" {
  count         = local.create ? 1 : 0
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  display_name  = "Symbol Integration"
  description   = "Symbol platform sign-in (OAuth confidential client). No admin role. Managed by the symbol-cloud-connect stack; revoke with Destroy."
  active        = !var.deactivate
  force_delete  = true # an active app cannot otherwise be deleted by Destroy

  # "Custom web application" template = confidential OAuth client.
  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  is_oauth_client = true
  # trusted = client authenticates with a JWT assertion signed by the key of an imported
  # certificate; confidential = client id + secret.
  client_type     = local.client_assertion ? "trusted" : "confidential"
  allowed_grants  = ["authorization_code", "client_credentials", "refresh_token"]
  redirect_uris   = [var.redirect_uri]
  show_in_my_apps = false

  dynamic "certificates" {
    for_each = local.client_assertion ? [local.certificate_alias] : []
    content {
      cert_alias = certificates.value
    }
  }

  urnietfparamsscimschemasoracleidcsextension_oci_tags {
    dynamic "freeform_tags" {
      for_each = var.freeform_tags
      content {
        key   = freeform_tags.key
        value = freeform_tags.value
      }
    }
  }

  lifecycle {
    ignore_changes = [schemas]
  }

  depends_on = [oci_identity_domains_oauth_client_certificate.symbol]
}

# Identity Propagation Trust: lets the app exchange a Symbol broker JWT for a UPST of the
# user named in `sub` (mapped to userName). No impersonation: the UPST is always the real
# user, with the user's own permissions. Only JWTs whose client_id claim is
# "symbol-broker" and that are presented by the Symbol app are accepted.
resource "oci_identity_domains_identity_propagation_trust" "symbol" {
  count                     = local.create ? 1 : 0
  idcs_endpoint             = local.idcs_endpoint
  schemas                   = ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"]
  name                      = "Symbol-Trust"
  description               = "Symbol broker JWT -> UPST token exchange. Managed by the symbol-cloud-connect stack."
  type                      = "JWT"
  issuer                    = var.issuer
  public_certificate        = var.ipt_certificate_b64
  subject_claim_name        = "sub"
  subject_mapping_attribute = "userName"
  subject_type              = "User"
  client_claim_name         = "client_id"
  client_claim_values       = ["symbol-broker"]
  # `name` of an identity-domain app is its OAuth client id.
  oauth_clients       = [oci_identity_domains_app.symbol[0].name]
  allow_impersonation = false
  active              = !var.deactivate

  lifecycle {
    ignore_changes = [schemas]
  }
}

# Warnings only: the connection code is still produced; Symbol's sign-in check will fail
# until they are fixed in the console.
check "reused_trust_certificate" {
  assert {
    condition     = local.existing_cert_matches
    error_message = "The existing trust \"${try(local.existing_trust.name, "")}\" trusts a different certificate than the one Symbol signs with. User sign-in will fail until its public certificate is replaced with Symbol's (Identity domain > Security > Identity propagation trusts)."
  }
}

check "reused_app_redirect_uri" {
  assert {
    condition     = !local.reuse || contains(local.existing_redirect_uris, var.redirect_uri)
    error_message = "The application attached to the existing trust (client id ${local.existing_client_id}) does not list ${var.redirect_uri} as a redirect URL. Add it under Integrated applications > OAuth configuration, otherwise sign-in fails with redirect_uri mismatch."
  }
}

output "domain_url" {
  description = "Identity domain URL (https://idcs-...identity.oraclecloud.com)."
  value       = local.domain_url
}

output "domain_id" {
  description = "Identity domain OCID."
  value       = var.identity_domain_id
}

output "client_id" {
  description = "OAuth client id of the Symbol Integration app (created, or attached to the reused trust)."
  value       = local.reuse ? local.existing_client_id : oci_identity_domains_app.symbol[0].name
}

output "ipt_id" {
  description = "Id of the Identity Propagation Trust (created, or reused)."
  value       = local.reuse ? local.existing_trust.id : oci_identity_domains_identity_propagation_trust.symbol[0].id
}

output "reused_existing" {
  description = "True when an existing trust for Symbol's issuer (and its app) was reused instead of created."
  value       = local.reuse
}

output "active" {
  description = "False once the stack was applied with prepare_removal (app and trust deactivated)."
  value       = !var.deactivate
}

output "reuse_problem" {
  description = "Why a reused trust cannot be used as it is (empty when fine, or when nothing is reused). The root preflight fails on it."
  value = !local.reuse ? "" : (
    !try(local.existing_trust.active, false) ?
    "An Identity Propagation Trust for ${var.issuer} already exists in this identity domain (\"${try(local.existing_trust.name, "")}\") but it is INACTIVE. Activate it, or delete it so this stack can create Symbol's own, then run Plan again." :
    local.existing_client_id == "" ?
    "An Identity Propagation Trust for ${var.issuer} already exists in this identity domain (\"${try(local.existing_trust.name, "")}\") but no OAuth application is attached to it (oauthClients is empty). Attach the Symbol application to it, or delete it so this stack can create Symbol's own." :
    ""
  )
}

output "trust_name" {
  description = "Name of the trust in use."
  value       = local.reuse ? local.existing_trust.name : "Symbol-Trust"
}

output "auth_method" {
  description = "Client authentication method configured on the app."
  value       = var.auth_method
}
