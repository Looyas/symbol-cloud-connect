# FinOps (contract v2 §5.6). Consumers at Symbol:
#   ingestion-service  BigQuery jobs on <project>.<dataset>.gcp_focus_v1 (gcp_extractor.py)
#   inventory-collector, budget-system, cloud-api-rec  Resource Manager, Compute, Cloud Asset,
#                       Recommender (projects/<p>/locations/<l>/recommenders/<r>)
# Every Symbol call sets the quota project to project_id (x-goog-user-project), so the
# APIs are enabled here and the identity gets roles/serviceusage.serviceUsageConsumer.

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
  description = "Project hosting the billing dataset; BigQuery jobs and API quota are billed to it."
}

variable "member" {
  type        = string
  description = "IAM member of the FinOps identity (serviceAccount:<email>)."
}

variable "scope_type" {
  type        = string
  description = "project, folder or organization."
}

variable "scope_id" {
  type        = string
  description = "Project id, folder number or organisation number."
}

variable "dataset_id" {
  type        = string
  description = "Billing export dataset."
}

variable "dataset_location" {
  type        = string
  description = "Location used when the dataset is created."
}

variable "create_dataset" {
  type        = bool
  description = "Create (and manage) the dataset."
}

variable "create_focus_view" {
  type        = bool
  description = "Create (and manage) the gcp_focus_v1 view."
}

variable "billing_account_id" {
  type        = string
  description = "Billing account of the detailed export table (0123AB-CDEF45-6789AB)."
}

locals {
  # disable_on_destroy = false: other workloads may rely on them; destroying the
  # template must never switch an API off.
  services = toset([
    "bigquery.googleapis.com",
    "cloudasset.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "recommender.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])

  project_roles = toset([
    "roles/bigquery.jobUser",                  # run the ingestion queries (bigquery.jobs.create), billed to project_id
    "roles/serviceusage.serviceUsageConsumer", # serviceusage.services.use: quota project for every Symbol call
  ])

  # roles/recommender.viewer covers get/list on every project-level recommender,
  # including cost (cloudCostGeneral*) and CUD (usageCommitment*, spendBasedCommitment*)
  # recommendations: https://cloud.google.com/iam/docs/roles-permissions/recommender
  scope_roles = toset([
    "roles/browser",        # projects/folders list + get (budget scopes, billingInfo, hierarchy)
    "roles/compute.viewer", # instance / disk / address inventory, zones and regions
    "roles/recommender.viewer",
    "roles/cloudasset.viewer", # searchAllResources inventory
    # storage.buckets.get/list only (no object data, no IAM policy): inventory-collector
    # bucket metadata. "Storage Bucket Viewer" (Beta stage at the time of writing):
    # https://cloud.google.com/iam/docs/roles-permissions/storage
    "roles/storage.bucketViewer",
  ])

  source_table = "gcp_billing_export_resource_v1_${replace(var.billing_account_id, "-", "_")}"
  dataset_id   = var.create_dataset ? google_bigquery_dataset.billing[0].dataset_id : var.dataset_id
  table_id     = "gcp_focus_v1"
}

resource "google_project_service" "this" {
  for_each = local.services

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# Created only when absent. delete_contents_on_destroy = false and `prevent_destroy`
# cannot be conditional (count): symbol-setup.sh --destroy removes the dataset from the
# state before destroying, so the billing data the export writes here is always kept.
resource "google_bigquery_dataset" "billing" {
  count = var.create_dataset ? 1 : 0

  project                    = var.project_id
  dataset_id                 = var.dataset_id
  location                   = var.dataset_location
  friendly_name              = "Cloud Billing export"
  description                = "Cloud Billing BigQuery export (detailed usage cost). Created by symbol-cloud-connect; kept on revocation."
  delete_contents_on_destroy = false

  depends_on = [google_project_service.this]
}

# FOCUS view read by Symbol's ingestion (SELECT * ... WHERE DATE(ChargePeriodStart) ...).
# The SQL is Google's FOCUS v1.0 GA BigQuery view adapted to the column names Symbol's
# gcp_transformer.py reads; every difference is documented in focus_view.sql.tftpl.
# Being in the same dataset as the export table, it is readable with dataViewer on the
# dataset alone (no authorized view needed).
resource "google_bigquery_table" "focus" {
  count = var.create_focus_view ? 1 : 0

  project             = var.project_id
  dataset_id          = local.dataset_id
  table_id            = local.table_id
  description         = "FOCUS v1.0 view of the Cloud Billing detailed export for Symbol (symbol-cloud-connect). Holds no data; safe to delete."
  deletion_protection = false

  view {
    use_legacy_sql = false
    query = templatefile("${path.module}/focus_view.sql.tftpl", {
      project            = var.project_id
      dataset            = local.dataset_id
      source_table       = local.source_table
      billing_account_id = var.billing_account_id
    })
  }

  depends_on = [google_project_service.this]
}

resource "google_bigquery_dataset_iam_member" "data_viewer" {
  project    = var.project_id
  dataset_id = local.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = var.member

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "project" {
  for_each = local.project_roles

  project = var.project_id
  role    = each.key
  member  = var.member
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

output "dataset_id" {
  description = "Billing dataset."
  value       = local.dataset_id
}

output "table_id" {
  description = "FOCUS view Symbol reads."
  value       = local.table_id
}

output "focus_view_created" {
  description = "True when this template manages gcp_focus_v1."
  value       = var.create_focus_view
}

output "focus_view_sql" {
  description = "Rendered view SQL (for review and for Symbol's manual guide)."
  value = templatefile("${path.module}/focus_view.sql.tftpl", {
    project            = var.project_id
    dataset            = var.dataset_id
    source_table       = local.source_table
    billing_account_id = var.billing_account_id
  })
}

output "granted_roles" {
  description = "Every role granted to the FinOps identity, by resource."
  value = {
    dataset = ["roles/bigquery.dataViewer"]
    project = sort(tolist(local.project_roles))
    scope   = sort(tolist(local.scope_roles))
  }
}

# Read back from the resources themselves (review and tests).
output "iam_grants" {
  description = "Every grant to the FinOps identity: target, role, member."
  value = concat(
    [{ target = "dataset:${google_bigquery_dataset_iam_member.data_viewer.project}.${google_bigquery_dataset_iam_member.data_viewer.dataset_id}", role = google_bigquery_dataset_iam_member.data_viewer.role, member = google_bigquery_dataset_iam_member.data_viewer.member }],
    [for g in google_project_iam_member.project : { target = "projects/${g.project}", role = g.role, member = g.member }],
    [for g in google_project_iam_member.scope : { target = "projects/${g.project}", role = g.role, member = g.member }],
    [for g in google_folder_iam_member.scope : { target = g.folder, role = g.role, member = g.member }],
    [for g in google_organization_iam_member.scope : { target = "organizations/${g.org_id}", role = g.role, member = g.member }],
  )
}

output "enabled_services" {
  description = "APIs enabled in project_id, with their disable_on_destroy flag."
  value       = { for k, s in google_project_service.this : k => { project = s.project, disable_on_destroy = s.disable_on_destroy } }
}

output "dataset" {
  description = "The dataset this template created, or null."
  value       = try({ location = google_bigquery_dataset.billing[0].location, delete_contents_on_destroy = google_bigquery_dataset.billing[0].delete_contents_on_destroy }, null)
}

output "focus_view" {
  description = "The FOCUS view this template created, or null."
  value = try({
    table_id            = google_bigquery_table.focus[0].table_id
    dataset_id          = google_bigquery_table.focus[0].dataset_id
    deletion_protection = google_bigquery_table.focus[0].deletion_protection
    use_legacy_sql      = google_bigquery_table.focus[0].view[0].use_legacy_sql
    query               = google_bigquery_table.focus[0].view[0].query
  }, null)
}
