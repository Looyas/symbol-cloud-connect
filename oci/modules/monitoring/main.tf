# Monitoring: Cloud Guard problems -> Events rule -> Stream, consumed by Symbol's
# monitoring-service with the symbol-observability key (plan §3 ③, §4.4 rows 5-6).
#
# Providers:
#   oci       stack region: stream pool, stream, Events rule (they must share a region)
#   oci.home  home region:  Events service policy, Cloud Guard configuration and target

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source                = "oracle/oci"
      version               = ">= 9.3.0"
      configuration_aliases = [oci.home]
    }
  }
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID."
}

variable "region" {
  type        = string
  description = "Stack region (where the stream and the Events rule are created)."
}

variable "home_region" {
  type        = string
  description = "Tenancy home region (Cloud Guard reporting region when this stack enables Cloud Guard)."
}

variable "compartment_id" {
  type        = string
  description = "Compartment of the stream pool and stream (may be the tenancy OCID)."
}

variable "extra_event_types" {
  type        = list(string)
  default     = []
  description = "Additional event types forwarded to the stream."
}

variable "create_cloud_guard" {
  type        = string
  description = "auto or never (see root variables)."
}

variable "freeform_tags" {
  type        = map(string)
  description = "Contract tags."
}

locals {
  scope         = var.compartment_id == var.tenancy_ocid ? "tenancy" : "compartment id ${var.compartment_id}"
  target_name   = "symbol-cloud-guard-root"
  event_types   = distinct(concat(["com.oraclecloud.cloudguard.problemdetected"], var.extra_event_types))
  oracle_owner  = "ORACLE"
  active_states = ["ACTIVE"]
}

###############################################################################
# Stream (1 partition, 24 h retention) in a dedicated pool.
# https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/streaming_stream_pool.html
# https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/streaming_stream.html
###############################################################################

resource "oci_streaming_stream_pool" "this" {
  compartment_id = var.compartment_id
  name           = "symbol-monitoring-pool"
  freeform_tags  = var.freeform_tags
}

resource "oci_streaming_stream" "this" {
  name               = "symbol-monitoring-stream"
  stream_pool_id     = oci_streaming_stream_pool.this.id
  partitions         = 1
  retention_in_hours = 24
  freeform_tags      = var.freeform_tags
}

###############################################################################
# Events: the Events service needs permission to write to the stream.
# Oracle's Events IAM page only documents user and cross-tenancy statements
# (https://docs.oracle.com/en-us/iaas/Content/Events/Concepts/eventspolicy.htm); the
# service policy below is the documented community pattern
# (https://apextips.blogspot.com/2019/10/oci-logging-object-events-with.html uses
# "allow service cloudEvents to use streams"). We grant the narrower stream-push
# resource type (PutMessages only, per
# https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/streamingpolicyreference.htm).
# stream-push supports no target.stream.id variable, so the grant is scoped to the
# compartment. POC P2 confirms whether it is needed; it is harmless if not.
###############################################################################

resource "oci_identity_policy" "events" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "symbol-events-policy"
  description    = "Lets the OCI Events service deliver Cloud Guard events to the Symbol monitoring stream."
  statements     = ["allow service cloudEvents to use stream-push in ${local.scope}"]
  freeform_tags  = var.freeform_tags
}

# The rule lives in the root compartment: a rule matches events of its compartment and
# all sub-compartments, and Cloud Guard problems can concern any compartment.
resource "oci_events_rule" "this" {
  compartment_id = var.tenancy_ocid
  display_name   = "symbol-monitoring-rule"
  description    = "Forwards Cloud Guard problems to the Symbol monitoring stream."
  is_enabled     = true
  condition      = jsonencode({ eventType = local.event_types })
  freeform_tags  = var.freeform_tags

  actions {
    action {
      action_type = "OSS"
      is_enabled  = true
      stream_id   = oci_streaming_stream.this.id
      description = "Symbol monitoring stream"
    }
  }

  depends_on = [oci_identity_policy.events]
}

###############################################################################
# Cloud Guard.
#
# Rule: never take over a Cloud Guard setup the customer already uses. This stack manages
# Cloud Guard (configuration + one root target) only when create_cloud_guard = "auto" and
#   - Cloud Guard is not ENABLED, or
#   - it is ENABLED in the home region and either our target already exists (we enabled it
#     on a previous apply: keeps the decision stable across applies) or there is no target
#     at all (e.g. a previous apply failed after enabling it, or after a Destroy).
# Targets are only listed when Cloud Guard is enabled; the API rejects calls otherwise.
#
# Destroy: the provider's delete for oci_cloud_guard_cloud_guard_configuration is a no-op
# (Cloud Guard stays enabled); the Symbol target is deleted.
# https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/cloud_guard_cloud_guard_configuration.html
# https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/cloud_guard_target.html
###############################################################################

data "oci_cloud_guard_cloud_guard_configuration" "current" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
}

locals {
  cg_status       = data.oci_cloud_guard_cloud_guard_configuration.current.status
  cg_enabled      = upper(coalesce(local.cg_status, "DISABLED")) == "ENABLED"
  cg_region       = data.oci_cloud_guard_cloud_guard_configuration.current.reporting_region
  inspect_targets = var.create_cloud_guard == "auto" && local.cg_enabled && local.cg_region == var.home_region
}

data "oci_cloud_guard_targets" "existing" {
  provider                  = oci.home
  count                     = local.inspect_targets ? 1 : 0
  compartment_id            = var.tenancy_ocid
  compartment_id_in_subtree = true
  access_level              = "ACCESSIBLE"
}

locals {
  existing_targets = [
    for t in flatten([for c in try(data.oci_cloud_guard_targets.existing[0].target_collection, []) : c.items]) : t
    if contains(local.active_states, t.state)
  ]
  symbol_target_exists = length([for t in local.existing_targets : t if t.display_name == local.target_name]) > 0

  manage_cloud_guard = var.create_cloud_guard == "auto" && (
    !local.cg_enabled || (local.inspect_targets && (local.symbol_target_exists || length(local.existing_targets) == 0))
  )
}

resource "oci_cloud_guard_cloud_guard_configuration" "this" {
  provider              = oci.home
  count                 = local.manage_cloud_guard ? 1 : 0
  compartment_id        = var.tenancy_ocid
  reporting_region      = local.cg_enabled ? local.cg_region : var.home_region
  status                = "ENABLED"
  self_manage_resources = false
}

# Oracle-managed recipes become listable once Cloud Guard is enabled, hence depends_on
# (the read is deferred to apply time on the first run).
data "oci_cloud_guard_detector_recipes" "oracle" {
  provider       = oci.home
  count          = local.manage_cloud_guard ? 1 : 0
  compartment_id = var.tenancy_ocid
  depends_on     = [oci_cloud_guard_cloud_guard_configuration.this]
}

data "oci_cloud_guard_responder_recipes" "oracle" {
  provider       = oci.home
  count          = local.manage_cloud_guard ? 1 : 0
  compartment_id = var.tenancy_ocid
  depends_on     = [oci_cloud_guard_cloud_guard_configuration.this]
}

locals {
  oracle_detector_recipes = [
    for r in flatten([for c in try(data.oci_cloud_guard_detector_recipes.oracle[0].detector_recipe_collection, []) : c.items]) : r
    if r.owner == local.oracle_owner && contains(local.active_states, r.state)
  ]
  configuration_recipe_id = try([for r in local.oracle_detector_recipes : r.id if r.detector == "IAAS_CONFIGURATION_DETECTOR"][0], "")
  activity_recipe_id      = try([for r in local.oracle_detector_recipes : r.id if r.detector == "IAAS_ACTIVITY_DETECTOR"][0], "")
  responder_recipe_id = try([
    for r in flatten([for c in try(data.oci_cloud_guard_responder_recipes.oracle[0].responder_recipe_collection, []) : c.items]) : r.id
    if r.owner == local.oracle_owner && contains(local.active_states, r.state)
  ][0], "")
}

resource "oci_cloud_guard_target" "root" {
  provider             = oci.home
  count                = local.manage_cloud_guard ? 1 : 0
  compartment_id       = var.tenancy_ocid
  display_name         = local.target_name
  description          = "Cloud Guard target created by the Symbol stack because Cloud Guard was not in use. Oracle-managed recipes."
  target_resource_id   = var.tenancy_ocid
  target_resource_type = "COMPARTMENT"
  freeform_tags        = var.freeform_tags

  target_detector_recipes {
    detector_recipe_id = local.configuration_recipe_id
  }

  target_detector_recipes {
    detector_recipe_id = local.activity_recipe_id
  }

  # The Oracle-managed responder recipe contains the "Cloud Event" responder that emits
  # problem events to the Events service (POC P3 confirms the event flow end to end).
  target_responder_recipes {
    responder_recipe_id = local.responder_recipe_id
  }

  lifecycle {
    precondition {
      condition     = local.configuration_recipe_id != "" && local.activity_recipe_id != "" && local.responder_recipe_id != ""
      error_message = "Could not find the Oracle-managed Cloud Guard recipes (configuration/activity detector, responder) in the tenancy. Set create_cloud_guard = never and enable Cloud Guard manually."
    }
  }

  depends_on = [oci_cloud_guard_cloud_guard_configuration.this]
}

locals {
  cloud_guard_status = local.manage_cloud_guard ? oci_cloud_guard_cloud_guard_configuration.this[0].status : coalesce(local.cg_status, "DISABLED")
  cloud_guard_region = local.manage_cloud_guard ? oci_cloud_guard_cloud_guard_configuration.this[0].reporting_region : (local.cg_enabled ? local.cg_region : null)
}

output "stream_ocid" {
  description = "Stream OCID."
  value       = oci_streaming_stream.this.id
}

output "messages_endpoint" {
  description = "Messages endpoint of the stream (https://cell-N.streaming.<region>.oci.oraclecloud.com)."
  value       = oci_streaming_stream.this.messages_endpoint
}

output "stream_region" {
  description = "Region of the stream."
  value       = var.region
}

output "compartment_id" {
  description = "Compartment of the stream."
  value       = var.compartment_id
}

output "cloud_guard_status" {
  description = "Cloud Guard status after apply (ENABLED, DISABLED)."
  value       = local.cloud_guard_status
}

output "cloud_guard_reporting_region" {
  description = "Cloud Guard reporting region (null when Cloud Guard is disabled)."
  value       = local.cloud_guard_region
}

output "cloud_guard_managed_by_symbol" {
  description = "True when this stack enabled Cloud Guard and owns its root target."
  value       = local.manage_cloud_guard
}
