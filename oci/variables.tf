# Inputs follow OCI-CLOUD-SETUP-CONTRACT.md §7. Variable names are part of the contract
# (connections-service builds the Resource Manager deep link from them): do not rename.
#
# Terraform 1.5 cannot validate one variable against another. Cross-variable rules
# (for example "enable_signin requires identity_domain_id") are enforced as lifecycle
# preconditions on terraform_data.preflight in main.tf, so they fail at plan time.

###############################################################################
# Injected by Resource Manager (hidden in schema.yaml)
###############################################################################

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID. Injected by Resource Manager."

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.[a-z0-9-]+\\.[a-z0-9-]*\\.[a-z0-9]+$", var.tenancy_ocid))
    error_message = "tenancy_ocid must be a tenancy OCID (ocid1.tenancy.<realm>..<id>)."
  }
}

variable "region" {
  type        = string
  description = "Region the stack runs in. Injected by Resource Manager. Regional resources (stream, Events rule) are created here."

  validation {
    condition     = can(regex("^[a-z]{2,}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an OCI region identifier such as eu-frankfurt-1."
  }
}

variable "user_ocid" {
  type        = string
  default     = ""
  description = "Local runs only: OCID of the user whose API key signs the requests. Leave empty in Resource Manager."
}

variable "fingerprint" {
  type        = string
  default     = ""
  description = "Local runs only: fingerprint of the API key. Leave empty in Resource Manager."
}

variable "private_key_path" {
  type        = string
  default     = ""
  description = "Local runs only: path to the API private key. Leave empty in Resource Manager."
}

# tflint-ignore: terraform_unused_declarations
variable "current_user_ocid" {
  type        = string
  default     = ""
  description = "Injected by Resource Manager (the user running the job). Declared so the form can hide it; not used."
}

###############################################################################
# From the Symbol deep link (contract §7.1) - pre-filled, do not change
###############################################################################

variable "symbol_org_id" {
  type        = string
  description = "Symbol organisation id. Echoed in the connection code and in the symbol-org tag."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", var.symbol_org_id))
    error_message = "symbol_org_id must be 1-128 characters: letters, digits, '_', '.', ':' or '-'."
  }
}

variable "setup_session_id" {
  type        = string
  description = "Symbol setup session id (UUID). Echoed in the connection code; the code is only accepted for this session."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.setup_session_id))
    error_message = "setup_session_id must be a UUID."
  }
}

variable "template_version" {
  type        = string
  default     = "oci-v1.0.2"
  description = "Version of this template. Hard-coded to the release; scripts/package.sh refuses to build if it differs from the tag."

  validation {
    condition     = can(regex("^oci-v[0-9]+\\.[0-9]+\\.[0-9]+$", var.template_version))
    error_message = "template_version must look like oci-v1.2.3."
  }
}

variable "symbol_issuer" {
  type        = string
  default     = "https://platform.symbole.ai/"
  description = "Issuer (iss claim) of the JWTs Symbol's broker presents to the Identity Propagation Trust."

  validation {
    condition     = can(regex("^https://[^\\s]+$", var.symbol_issuer))
    error_message = "symbol_issuer must be an https URL."
  }
}

variable "redirect_uri" {
  type        = string
  default     = "https://platform.symbole.ai/callback"
  description = "The only redirect URI registered on the Symbol confidential application."

  validation {
    condition     = can(regex("^https://[^\\s]+$", var.redirect_uri))
    error_message = "redirect_uri must be an https URL."
  }
}

variable "symbol_ipt_certificate_url" {
  type        = string
  default     = ""
  description = "Public URL of Symbol's X.509 certificate (PEM) that verifies broker JWTs. Ignored when symbol_ipt_certificate_pem is set."

  validation {
    condition     = var.symbol_ipt_certificate_url == "" || can(regex("^https://[^\\s]+$", var.symbol_ipt_certificate_url))
    error_message = "symbol_ipt_certificate_url must be empty or an https URL."
  }
}

variable "symbol_ipt_certificate_pem" {
  type        = string
  default     = ""
  description = "Inline PEM of Symbol's IPT certificate. Takes precedence over symbol_ipt_certificate_url."

  validation {
    condition     = var.symbol_ipt_certificate_pem == "" || can(regex("-----BEGIN CERTIFICATE-----", var.symbol_ipt_certificate_pem))
    error_message = "symbol_ipt_certificate_pem must be empty or a PEM certificate (-----BEGIN CERTIFICATE-----)."
  }
}

variable "finops_public_key_url" {
  type        = string
  default     = ""
  description = "Public URL of the symbol-finops API public key (PEM), generated by Symbol for this session. Ignored when finops_public_key_pem is set."

  validation {
    condition     = var.finops_public_key_url == "" || can(regex("^https://[^\\s]+$", var.finops_public_key_url))
    error_message = "finops_public_key_url must be empty or an https URL."
  }
}

variable "finops_public_key_pem" {
  type        = string
  default     = ""
  description = "Inline PEM of the symbol-finops API public key. Takes precedence over finops_public_key_url."

  validation {
    condition     = var.finops_public_key_pem == "" || can(regex("-----BEGIN PUBLIC KEY-----", var.finops_public_key_pem))
    error_message = "finops_public_key_pem must be empty or a PEM public key (-----BEGIN PUBLIC KEY-----)."
  }
}

variable "observability_public_key_url" {
  type        = string
  default     = ""
  description = "Public URL of the symbol-observability API public key (PEM). Ignored when observability_public_key_pem is set."

  validation {
    condition     = var.observability_public_key_url == "" || can(regex("^https://[^\\s]+$", var.observability_public_key_url))
    error_message = "observability_public_key_url must be empty or an https URL."
  }
}

variable "observability_public_key_pem" {
  type        = string
  default     = ""
  description = "Inline PEM of the symbol-observability API public key. Takes precedence over observability_public_key_url."

  validation {
    condition     = var.observability_public_key_pem == "" || can(regex("-----BEGIN PUBLIC KEY-----", var.observability_public_key_pem))
    error_message = "observability_public_key_pem must be empty or a PEM public key (-----BEGIN PUBLIC KEY-----)."
  }
}

variable "symbol_egress_cidrs" {
  type        = list(string)
  default     = []
  description = "Symbol's published egress IPv4 CIDRs. They form the 'symbol' network source that every service-identity policy is conditioned on."

  validation {
    condition = alltrue([
      for c in var.symbol_egress_cidrs :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$", c)) && can(cidrhost(c, 0))
    ])
    error_message = "Every symbol_egress_cidrs entry must be an IPv4 CIDR such as 203.0.113.10/32."
  }
}

variable "enable_signin" {
  type        = bool
  default     = false
  description = "Create the Symbol confidential application and Identity Propagation Trust (user sign-in)."
}

variable "enable_finops" {
  type        = bool
  default     = false
  description = "Create the symbol-finops service identity and its read-only cost/inventory policy."
}

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Create the monitoring stream, the Cloud Guard Events rule and the symbol-observability monitoring permissions."
}

variable "enable_security" {
  type        = bool
  default     = false
  description = "Grant symbol-observability the read/inspect permissions used by Symbol's CIS security scan."
}

variable "signin_auth_method" {
  type        = string
  default     = "CLIENT_SECRET"
  description = "How Symbol authenticates the confidential application: CLIENT_SECRET (default) or CLIENT_ASSERTION (trusted client with Symbol's certificate)."

  validation {
    condition     = contains(["CLIENT_SECRET", "CLIENT_ASSERTION"], var.signin_auth_method)
    error_message = "signin_auth_method must be CLIENT_SECRET or CLIENT_ASSERTION."
  }
}

variable "symbol_client_cert_url" {
  type        = string
  default     = ""
  description = "CLIENT_ASSERTION only: public URL of Symbol's client-assertion certificate (PEM). Ignored when symbol_client_cert_pem is set."

  validation {
    condition     = var.symbol_client_cert_url == "" || can(regex("^https://[^\\s]+$", var.symbol_client_cert_url))
    error_message = "symbol_client_cert_url must be empty or an https URL."
  }
}

variable "symbol_client_cert_pem" {
  type        = string
  default     = ""
  description = "CLIENT_ASSERTION only: inline PEM of Symbol's client-assertion certificate. Takes precedence over symbol_client_cert_url."

  validation {
    condition     = var.symbol_client_cert_pem == "" || can(regex("-----BEGIN CERTIFICATE-----", var.symbol_client_cert_pem))
    error_message = "symbol_client_cert_pem must be empty or a PEM certificate (-----BEGIN CERTIFICATE-----)."
  }
}

###############################################################################
# From the Resource Manager form (contract §7.2)
###############################################################################

variable "identity_domain_id" {
  type        = string
  default     = ""
  description = "OCID of the identity domain your users sign in with. Required when sign-in is enabled."

  validation {
    condition     = var.identity_domain_id == "" || can(regex("^ocid1\\.domain\\.[a-z0-9-]+\\.[a-z0-9-]*\\.[a-z0-9]+$", var.identity_domain_id))
    error_message = "identity_domain_id must be empty or an identity domain OCID (ocid1.domain...)."
  }
}

variable "monitoring_compartment_id" {
  type        = string
  default     = ""
  description = "Compartment for the monitoring stream pool and stream. Empty means the tenancy (root compartment)."

  validation {
    condition     = var.monitoring_compartment_id == "" || can(regex("^ocid1\\.(compartment|tenancy)\\.[a-z0-9-]+\\.[a-z0-9-]*\\.[a-z0-9]+$", var.monitoring_compartment_id))
    error_message = "monitoring_compartment_id must be empty or a compartment/tenancy OCID."
  }
}

variable "scan_compartment_id" {
  type        = string
  default     = ""
  description = "Optional: limit the security-scan permissions to this compartment. Empty means the whole tenancy."

  validation {
    condition     = var.scan_compartment_id == "" || can(regex("^ocid1\\.(compartment|tenancy)\\.[a-z0-9-]+\\.[a-z0-9-]*\\.[a-z0-9]+$", var.scan_compartment_id))
    error_message = "scan_compartment_id must be empty or a compartment/tenancy OCID."
  }
}

variable "extra_event_types" {
  type        = list(string)
  default     = []
  description = "Additional OCI event types to forward to the monitoring stream, besides com.oraclecloud.cloudguard.problemdetected."

  validation {
    condition     = alltrue([for e in var.extra_event_types : can(regex("^com\\.oraclecloud\\.[a-z0-9]+(\\.[a-z0-9_-]+)+$", e))])
    error_message = "Each extra_event_types entry must be an OCI event type such as com.oraclecloud.cloudguard.problemdismissed."
  }
}

variable "prepare_removal" {
  type        = bool
  default     = false
  description = "Sign-in only. Deactivates the Symbol Integration app and the Symbol-Trust trust (sign-in through Symbol stops at once). OCI refuses to delete an ACTIVE app, so revoking is: tick this, Apply, then Destroy."
}

variable "create_cloud_guard" {
  type        = string
  default     = "auto"
  description = "auto: enable Cloud Guard (home region, Oracle-managed recipes on the root compartment) only if it is not already enabled. never: do not touch Cloud Guard."

  validation {
    condition     = contains(["auto", "never"], var.create_cloud_guard)
    error_message = "create_cloud_guard must be auto or never."
  }
}
