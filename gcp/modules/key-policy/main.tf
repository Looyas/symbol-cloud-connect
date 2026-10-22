# May this project create service-account keys? (gcp-v2)
#
# Organisations created since 3 May 2024 forbid user-managed service-account keys by
# default. Two constraints do it, and both are checked: the legacy boolean
# iam.disableServiceAccountKeyCreation and its managed successor
# iam.managed.disableServiceAccountKeyCreation.
#
# 1. READ. The effective policy of each constraint on the project, from the Org Policy
#    v2 API (projects.policies.getEffectivePolicy), as the admin running the setup.
#    A project with no organisation has no organisation policy: nothing is read.
#    enforced      -> step 2
#    not_enforced  -> nothing to do
#    unknown       -> the policy could not be read (no orgpolicy.policies.get, API
#                     disabled): a warning (check block), and the key creation itself
#                     says whether it is allowed.
#
# 2. STOP, OR LIFT IT FOR THIS PROJECT ONLY. Without allow_key_creation_exception the
#    plan stops BEFORE anything is created, naming the constraint and the fix (the
#    precondition on terraform_data.key_creation_gate in the root module, which also
#    holds the "could not read the policy" warning: both are root-level so the tests can
#    expect them). With it,
#    a project-level policy (enforce = false) is created for both constraints -- for
#    both, not only the enforced ones, so the set never changes between runs: once the
#    exception exists the effective policy reads "not enforced", and a set computed from
#    the effective policy would delete the exception on the next run. Creating one
#    needs roles/orgpolicy.policyAdmin, which is granted on the organisation.
#    The exception is part of this deployment: symbol-setup.sh --destroy removes it.
#
# 3. WAIT. A new organisation policy takes up to a couple of minutes to reach IAM; the
#    keys are created after a pause, not at the first possible moment.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Project where the keys are created."
}

variable "organization_id" {
  type        = string
  description = "Organisation of the project; empty when it has none (then no policy applies)."
}

variable "check_enabled" {
  type        = bool
  description = "Read and enforce the policies. False in destroy mode: revoking never depends on them."
}

variable "allow_exception" {
  type        = bool
  description = "Create a project-level exception (enforce = false) for both key-creation constraints."
}

variable "propagation_seconds" {
  type        = number
  default     = 90
  description = "Pause between creating the exception and creating the keys."
}

locals {
  constraints = ["iam.disableServiceAccountKeyCreation", "iam.managed.disableServiceAccountKeyCreation"]
  has_org     = var.organization_id != ""
  read        = var.check_enabled && local.has_org
  exception   = var.allow_exception && local.has_org
  # The exceptions' names, built from inputs known at plan time. NOT read back
  # from google_org_policy_policy.name: the provider stores that in its SHORT form
  # (iam.disableServiceAccountKeyCreation, GetResourceNameFromSelfLink in its
  # encoder), so a value derived from it changes during apply and Terraform aborts
  # with "Provider produced inconsistent final plan" (gcp-v2.0.0 with the exception).
  exception_names = local.exception ? [for c in sort(local.constraints) : "projects/${var.project_id}/policies/${c}"] : []
}

data "google_client_config" "current" {}

data "http" "effective_policy" {
  for_each = local.read ? toset(local.constraints) : toset([])

  url    = "https://orgpolicy.googleapis.com/v2/projects/${var.project_id}/policies/${each.key}:getEffectivePolicy"
  method = "GET"

  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${data.google_client_config.current.access_token}"
    # The admin's user credentials need a quota project for this API: the customer's
    # own project, like every other call of this template (providers.tf).
    "X-Goog-User-Project" = var.project_id
  }

  retry {
    attempts     = 2
    min_delay_ms = 1000
  }
}

locals {
  # enforced | not_enforced | unknown, per constraint. An Org Policy v2 policy is
  # enforced when one of its rules says enforce = true (a rule with a condition counts:
  # the condition may match this project).
  policy_state = {
    for c, d in data.http.effective_policy : c => (
      d.status_code != 200 || !can(jsondecode(d.response_body)) ? "unknown" : (
        anytrue([for r in try(jsondecode(d.response_body).spec.rules, []) : try(r.enforce, false) == true])
        ? "enforced" : "not_enforced"
      )
    )
  }
  enforced = sort([for c, s in local.policy_state : c if s == "enforced"])
  unknown  = sort([for c, s in local.policy_state : c if s == "unknown"])
}

resource "google_org_policy_policy" "allow_key_creation" {
  for_each = local.exception ? toset(local.constraints) : toset([])

  name   = "projects/${var.project_id}/policies/${each.key}"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "FALSE"
    }
  }
}

resource "time_sleep" "propagation" {
  count = local.exception ? 1 : 0

  create_duration = "${var.propagation_seconds}s"
  # Known at plan time (see local.exception_names); the wait starts after the
  # policies exist because of depends_on, not because of these values.
  triggers = {
    policies = join(",", local.exception_names)
  }

  depends_on = [google_org_policy_policy.allow_key_creation]
}

output "ready" {
  description = "Depend on this before creating keys: any exception exists and has propagated."
  value = {
    exception = local.exception_names
    waited    = [for s in time_sleep.propagation : s.id]
  }
}

output "constraints" {
  description = "The key-creation constraints this module reads (and lifts on request)."
  value       = local.constraints
}

output "enforced" {
  description = "Constraints whose effective policy forbids key creation on the project."
  value       = local.enforced
}

output "unreadable" {
  description = "Constraints whose effective policy could not be read."
  value       = local.unknown
}

output "policy_state" {
  description = "Effective state of each key-creation constraint (empty when nothing was read)."
  value       = local.policy_state
}

output "exception_created" {
  description = "Whether this deployment manages a project-level key-creation exception."
  value       = local.exception
}
