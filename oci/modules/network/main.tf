# Network source "symbol": Symbol's published egress CIDRs.
# Every allow statement granted to the Symbol service groups carries
#   where request.networkSource.name='symbol'
# so the symbol-finops / symbol-observability API keys are useless outside Symbol's
# egress IPs, even if a key leaked.
# https://docs.oracle.com/en-us/iaas/Content/Identity/networksources/managingnetworksources.htm
# Network sources are tenancy-level IAM resources: compartment = tenancy, home region.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.3.0"
    }
  }
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID (network sources live in the root compartment)."
}

variable "egress_cidrs" {
  type        = list(string)
  description = "Symbol egress IPv4 CIDRs."
}

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags applied to every resource."
}

resource "oci_identity_network_source" "symbol" {
  compartment_id     = var.tenancy_ocid
  name               = "symbol"
  description        = "Symbol egress IPs. Symbol service identities may only call OCI from these addresses."
  public_source_list = distinct(var.egress_cidrs)
  freeform_tags      = var.freeform_tags
}

output "name" {
  description = "Network source name, referenced by policy conditions. Using this output creates the dependency policy -> network source."
  value       = oci_identity_network_source.symbol.name
}
