# Symbol Cloud Connect for GCP (contract v2 §5.6).
#
# Run by symbol-setup.sh from the customer's Cloud Shell. The script guarantees
# Terraform >= 1.5 (it installs a pinned, checksum-verified release otherwise), so the
# language stays 1.5-compatible: cross-variable rules are lifecycle preconditions on
# terraform_data.preflight (main.tf), not variable validations.
#
# Providers are pinned to exact versions: a release of this template is immutable and
# must plan the same way on every run. .terraform.lock.hcl is committed (with hashes for
# linux/darwin/windows) so `terraform init` also verifies the provider binaries.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.7.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.2"
    }
  }

  # Partial configuration: symbol-setup.sh passes
  #   -backend-config=bucket=<project>-symbol-tfstate
  #   -backend-config=prefix=symbol-cloud-connect/<org>
  # so any project admin can later upgrade or destroy from the same state.
  backend "gcs" {}
}
