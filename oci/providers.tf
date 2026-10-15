# In Resource Manager, authentication is injected automatically and user_ocid,
# fingerprint and private_key_path stay empty. They only matter for local runs
# (terraform plan from a workstation with an API key).

# Default provider: the region the stack runs in. Regional resources (stream pool,
# stream, Events rule) are created here.
provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}

# Home-region provider. IAM writes (network source, policies) and Cloud Guard
# configuration must target the tenancy home region:
# https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingregions.htm
# Identity-domain resources are addressed through their own idcs_endpoint, but we route
# them through this provider as well so that every identity write is in one place.
provider "oci" {
  alias            = "home"
  region           = local.home_region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}
