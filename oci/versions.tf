# OCI Resource Manager runs this stack with Terraform 1.5.x (the only non-deprecated
# version, see https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Reference/terraformversions.htm).
# Do not use language features newer than 1.5 (no cross-variable validation, no
# provider-defined functions).
#
# Providers are pinned to exact versions: a release of this template is immutable and must
# plan the same way on every run. New stacks fetch providers from the Terraform Registry,
# which is how hashicorp/http is made available
# (https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/providers.htm).
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "9.3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.2"
    }
  }
}
