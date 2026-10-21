# Monitoring (contract v2 §5.6). Consumer at Symbol: monitoring-service (StreamingPull
# on symbol-monitoring-sub; optional SCC findings on symbol-scc-sub).
#
#   Cloud Audit Logs --(sink symbol-audit-sink)--> topic symbol-monitoring --> symbol-monitoring-sub
#   SCC findings ----(notification symbol-scc)---> topic symbol-scc        --> symbol-scc-sub
#
# The observability identity only gets roles/pubsub.subscriber on the subscriptions.
# The sink and SCC write with Google-managed service agents granted publisher on the
# topics; no Symbol identity can publish.

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
  description = "Project hosting the topics and subscriptions."
}

variable "member" {
  type        = string
  description = "IAM member of the observability identity."
}

variable "scope_type" {
  type        = string
  description = "project, folder or organization: where the audit-log sink is created."
}

variable "scope_id" {
  type        = string
  description = "Project id, folder number or organisation number."
}

variable "organization_id" {
  type        = string
  description = "Organisation number (SCC)."
}

variable "enable_scc" {
  type        = bool
  description = "Create the SCC notification config, topic and subscription."
}

locals {
  services = toset(concat(
    ["pubsub.googleapis.com", "logging.googleapis.com"],
    var.enable_scc ? ["securitycenter.googleapis.com"] : [],
  ))

  # Admin Activity, Data Access, System Event and Policy Denied audit logs.
  # https://cloud.google.com/logging/docs/audit#audit_log_entry_structure
  audit_filter = "logName:\"cloudaudit.googleapis.com\""

  # Same value as the topic's id; spelled out so the plan shows it before apply.
  sink_destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${google_pubsub_topic.monitoring.name}"

  # 7 days: lets Symbol catch up after an outage of up to a week.
  retention = "604800s"

  writer_identity = one(concat(
    google_logging_project_sink.audit[*].writer_identity,
    google_logging_folder_sink.audit[*].writer_identity,
    google_logging_organization_sink.audit[*].writer_identity,
  ))
}

resource "google_project_service" "this" {
  for_each = local.services

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

###############################################################################
# Audit logs
###############################################################################

resource "google_pubsub_topic" "monitoring" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption at rest (default). CMEK needs a customer-owned KMS key, which this template does not create; messages are audit-log metadata.
  project = var.project_id
  name    = "symbol-monitoring"

  message_retention_duration = local.retention

  depends_on = [google_project_service.this]
}

resource "google_pubsub_subscription" "monitoring" {
  project = var.project_id
  name    = "symbol-monitoring-sub"
  topic   = google_pubsub_topic.monitoring.id

  ack_deadline_seconds       = 60
  message_retention_duration = local.retention

  # Never expire: a quiet project must not lose its subscription after 31 days.
  expiration_policy {
    ttl = ""
  }
}

# The sink lives where the scope says; folder and organisation sinks include children.
# unique_writer_identity = true (project sinks) gives a dedicated service agent; folder
# and organisation sinks always have one.
resource "google_logging_project_sink" "audit" {
  count = var.scope_type == "project" ? 1 : 0

  project                = var.scope_id
  name                   = "symbol-audit-sink"
  description            = "Cloud Audit Logs to Symbol monitoring (symbol-cloud-connect)."
  destination            = local.sink_destination
  filter                 = local.audit_filter
  unique_writer_identity = true
}

resource "google_logging_folder_sink" "audit" {
  count = var.scope_type == "folder" ? 1 : 0

  folder           = "folders/${var.scope_id}"
  name             = "symbol-audit-sink"
  description      = "Cloud Audit Logs to Symbol monitoring (symbol-cloud-connect)."
  destination      = local.sink_destination
  filter           = local.audit_filter
  include_children = true
}

resource "google_logging_organization_sink" "audit" {
  count = var.scope_type == "organization" ? 1 : 0

  org_id           = var.scope_id
  name             = "symbol-audit-sink"
  description      = "Cloud Audit Logs to Symbol monitoring (symbol-cloud-connect)."
  destination      = local.sink_destination
  filter           = local.audit_filter
  include_children = true
}

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.monitoring.name
  role    = "roles/pubsub.publisher"
  member  = local.writer_identity
}

resource "google_pubsub_subscription_iam_member" "monitoring" {
  project      = var.project_id
  subscription = google_pubsub_subscription.monitoring.name
  role         = "roles/pubsub.subscriber"
  member       = var.member
}

###############################################################################
# Security Command Center findings (optional, organisation scope). SCC API v2
# resource (the v1 google_scc_notification_config targets the older v1 API).
###############################################################################

resource "google_pubsub_topic" "scc" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption at rest (default). CMEK needs a customer-owned KMS key, which this template does not create; messages are audit-log metadata.
  count = var.enable_scc ? 1 : 0

  project                    = var.project_id
  name                       = "symbol-scc"
  message_retention_duration = local.retention

  depends_on = [google_project_service.this]
}

resource "google_pubsub_subscription" "scc" {
  count = var.enable_scc ? 1 : 0

  project = var.project_id
  name    = "symbol-scc-sub"
  topic   = google_pubsub_topic.scc[0].id

  ack_deadline_seconds       = 60
  message_retention_duration = local.retention

  expiration_policy {
    ttl = ""
  }
}

resource "google_scc_v2_organization_notification_config" "scc" {
  count = var.enable_scc ? 1 : 0

  organization = var.organization_id
  location     = "global"
  config_id    = "symbol-scc"
  description  = "Active SCC findings to Symbol monitoring (symbol-cloud-connect)."
  pubsub_topic = "projects/${var.project_id}/topics/${google_pubsub_topic.scc[0].name}"

  streaming_config {
    filter = "state = \"ACTIVE\""
  }

  depends_on = [google_project_service.this]
}

resource "google_pubsub_topic_iam_member" "scc_publisher" {
  count = var.enable_scc ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.scc[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_scc_v2_organization_notification_config.scc[0].service_account}"
}

resource "google_pubsub_subscription_iam_member" "scc" {
  count = var.enable_scc ? 1 : 0

  project      = var.project_id
  subscription = google_pubsub_subscription.scc[0].name
  role         = "roles/pubsub.subscriber"
  member       = var.member
}

output "subscription_id" {
  description = "Full name of the audit-log subscription."
  value       = "projects/${var.project_id}/subscriptions/${google_pubsub_subscription.monitoring.name}"
}

output "scc_subscription_id" {
  description = "Full name of the SCC subscription, or null."
  value       = var.enable_scc ? "projects/${var.project_id}/subscriptions/${google_pubsub_subscription.scc[0].name}" : null
}

output "writer_identity" {
  description = "Service agent the sink writes with (granted publisher on the topic)."
  value       = local.writer_identity
}

output "sink_kind" {
  description = "Which sink resource was created."
  value       = var.scope_type
}

output "sink" {
  description = "The audit-log sink as created."
  value = one(concat(
    [for s in google_logging_project_sink.audit : { parent = "projects/${s.project}", filter = s.filter, destination = s.destination, include_children = false, unique_writer_identity = s.unique_writer_identity }],
    [for s in google_logging_folder_sink.audit : { parent = s.folder, filter = s.filter, destination = s.destination, include_children = s.include_children, unique_writer_identity = true }],
    [for s in google_logging_organization_sink.audit : { parent = "organizations/${s.org_id}", filter = s.filter, destination = s.destination, include_children = s.include_children, unique_writer_identity = true }],
  ))
}

output "iam_grants" {
  description = "Every Pub/Sub grant: target, role, member."
  value = concat(
    [{ target = "topics/${google_pubsub_topic_iam_member.sink_publisher.topic}", role = google_pubsub_topic_iam_member.sink_publisher.role, member = google_pubsub_topic_iam_member.sink_publisher.member }],
    [{ target = "subscriptions/${google_pubsub_subscription_iam_member.monitoring.subscription}", role = google_pubsub_subscription_iam_member.monitoring.role, member = google_pubsub_subscription_iam_member.monitoring.member }],
    [for g in google_pubsub_topic_iam_member.scc_publisher : { target = "topics/${g.topic}", role = g.role, member = g.member }],
    [for g in google_pubsub_subscription_iam_member.scc : { target = "subscriptions/${g.subscription}", role = g.role, member = g.member }],
  )
}

output "subscription_settings" {
  description = "Delivery settings of the audit-log subscription."
  value = {
    ack_deadline_seconds       = google_pubsub_subscription.monitoring.ack_deadline_seconds
    message_retention_duration = google_pubsub_subscription.monitoring.message_retention_duration
  }
}

output "scc_organization" {
  description = "Organisation of the SCC notification config, or null."
  value       = try(google_scc_v2_organization_notification_config.scc[0].organization, null)
}
