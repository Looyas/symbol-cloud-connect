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

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags."
}

data "oci_identity_domain" "this" {
  domain_id = var.identity_domain_id
}

locals {
  idcs_endpoint    = data.oci_identity_domain.this.url
  client_assertion = var.auth_method == "CLIENT_ASSERTION"
  # The domain URL is returned with an explicit :443; the connection code carries the
  # canonical form https://idcs-<id>.identity.oraclecloud.com (contract §2 / plan §4.5).
  domain_url = trimsuffix(trimsuffix(local.idcs_endpoint, "/"), ":443")
  # Domain-wide alias of the imported client certificate (CLIENT_ASSERTION only).
  certificate_alias = "symbol-integration-client"
}

# CLIENT_ASSERTION: the provider cannot upload certificate content on the application
# itself (certificates.x509base64certificate is read-only in the schema). The certificate
# is imported as an OAuth client certificate and referenced from the app by alias.
resource "oci_identity_domains_oauth_client_certificate" "symbol" {
  count                 = local.client_assertion ? 1 : 0
  idcs_endpoint         = local.idcs_endpoint
  schemas               = ["urn:ietf:params:scim:schemas:oracle:idcs:OAuthClientCertificate"]
  certificate_alias     = local.certificate_alias
  x509base64certificate = var.client_certificate_b64
}

resource "oci_identity_domains_app" "symbol" {
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  display_name  = "Symbol Integration"
  description   = "Symbol platform sign-in (OAuth confidential client). No admin role. Managed by the symbol-cloud-connect stack; revoke with Destroy."
  active        = true
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
  oauth_clients       = [oci_identity_domains_app.symbol.name]
  allow_impersonation = false
  active              = true

  lifecycle {
    ignore_changes = [schemas]
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
  description = "OAuth client id of the Symbol Integration app."
  value       = oci_identity_domains_app.symbol.name
}

output "ipt_id" {
  description = "Id of the Symbol-Trust Identity Propagation Trust."
  value       = oci_identity_domains_identity_propagation_trust.symbol.id
}

output "auth_method" {
  description = "Client authentication method configured on the app."
  value       = var.auth_method
}
