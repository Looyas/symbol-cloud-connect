# Security (contract v2 §5.6). Consumer at Symbol: Security-agent-scanner (CIS GCP
# checks: Cloud Asset searchAllResources, IAM policies, compute, storage, logging,
# BigQuery metadata) at the chosen scope. Read-only roles only.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Customer project (API enablement / quota project)."
}

variable "member" {
  type        = string
  description = "IAM member of the observability identity."
}

variable "scope_type" {
  type        = string
  description = "project, folder or organization."
}

variable "scope_id" {
  type        = string
  description = "Project id, folder number or organisation number."
}

locals {
  services = toset([
    "cloudasset.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
  ])

  scope_roles = toset([
    "roles/viewer",               # basic read-only role required by the contract; broad (see PERMISSIONS.md "Notes")
    "roles/iam.securityReviewer", # get/list every IAM policy (allow policies on all resource types)
    "roles/cloudasset.viewer",    # searchAllResources / searchAllIamPolicies
  ])
}

resource "google_project_service" "this" {
  for_each = local.services

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_project_iam_member" "scope" {
  for_each = var.scope_type == "project" ? local.scope_roles : toset([])

  project = var.scope_id
  role    = each.key
  member  = var.member
}

resource "google_folder_iam_member" "scope" {
  for_each = var.scope_type == "folder" ? local.scope_roles : toset([])

  folder = "folders/${var.scope_id}"
  role   = each.key
  member = var.member
}

resource "google_organization_iam_member" "scope" {
  for_each = var.scope_type == "organization" ? local.scope_roles : toset([])

  org_id = var.scope_id
  role   = each.key
  member = var.member
}

output "granted_roles" {
  description = "Roles granted to the observability identity at the scope."
  value       = sort(tolist(local.scope_roles))
}

output "iam_grants" {
  description = "Every grant to the observability identity made by this module."
  value = concat(
    [for g in google_project_iam_member.scope : { target = "projects/${g.project}", role = g.role, member = g.member }],
    [for g in google_folder_iam_member.scope : { target = g.folder, role = g.role, member = g.member }],
    [for g in google_organization_iam_member.scope : { target = "organizations/${g.org_id}", role = g.role, member = g.member }],
  )
}
