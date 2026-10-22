# Offline tests with mocked providers (no GCP project, no credentials).
# Requires Terraform >= 1.7 (mock providers).
#   terraform init -backend=false && terraform test
#
# Every run that checks the connection code decodes it exactly like Symbol's decoder:
# strip the prefix, base64url -> standard alphabet, re-pad, base64decode, jsondecode;
# then compares the WHOLE object, so any extra, missing or renamed key fails (§5.7).
#
# The key files are FAKE (their "private_key" is a placeholder string, not a key): the
# google provider is mocked, and the overrides below give each key a deterministic id
# and key file. The reveal_* runs print the codes for tests/test_code_schema.py.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_client_config" {
    defaults = {
      access_token = "mock-access-token"
    }
  }

  mock_resource "google_logging_project_sink" {
    defaults = {
      writer_identity = "serviceAccount:service-123456789012@gcp-sa-logging.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_logging_folder_sink" {
    defaults = {
      writer_identity = "serviceAccount:service-folder-555@gcp-sa-logging.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_logging_organization_sink" {
    defaults = {
      writer_identity = "serviceAccount:service-org-987654321@gcp-sa-logging.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_scc_v2_organization_notification_config" {
    defaults = {
      service_account = "service-org-987654321@gcp-sa-scc-notification.iam.gserviceaccount.com"
    }
  }
}

# Org Policy v2 effective policies: key creation allowed, unless a run overrides it.
mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "{\"name\":\"projects/123456789012/policies/iam.disableServiceAccountKeyCreation\",\"spec\":{\"rules\":[{\"enforce\":false}]}}"
    }
  }
}

mock_provider "time" {}

# Service accounts and keys: deterministic e-mails, key ids and (fake) key files.
override_resource {
  target = module.identity[0].google_service_account.this["finops"]
  values = {
    email = "symbol-finops@acme-billing.iam.gserviceaccount.com"
    name  = "projects/acme-billing/serviceAccounts/symbol-finops@acme-billing.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.identity[0].google_service_account.this["observability"]
  values = {
    email = "symbol-observability@acme-billing.iam.gserviceaccount.com"
    name  = "projects/acme-billing/serviceAccounts/symbol-observability@acme-billing.iam.gserviceaccount.com"
  }
}

override_resource {
  target = module.identity[0].google_service_account_key.this["finops"]
  values = {
    name         = "projects/acme-billing/serviceAccounts/symbol-finops@acme-billing.iam.gserviceaccount.com/keys/0123456789abcdef0123456789abcdef01234567"
    private_key  = "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJvamVjdF9pZCI6ImFjbWUtYmlsbGluZyIsInByaXZhdGVfa2V5X2lkIjoiMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2NyIsInByaXZhdGVfa2V5IjoiZmFrZS1wcml2YXRlLWtleS1vZi1maW5vcHMtZm9yLXRlc3RzIiwiY2xpZW50X2VtYWlsIjoic3ltYm9sLWZpbm9wc0BhY21lLWJpbGxpbmcuaWFtLmdzZXJ2aWNlYWNjb3VudC5jb20iLCJjbGllbnRfaWQiOiIxMDAwMDAwMDAwMDAwMDAwMDAwMDEiLCJhdXRoX3VyaSI6Imh0dHBzOi8vYWNjb3VudHMuZ29vZ2xlLmNvbS9vL29hdXRoMi9hdXRoIiwidG9rZW5fdXJpIjoiaHR0cHM6Ly9vYXV0aDIuZ29vZ2xlYXBpcy5jb20vdG9rZW4iLCJhdXRoX3Byb3ZpZGVyX3g1MDlfY2VydF91cmwiOiJodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9vYXV0aDIvdjEvY2VydHMiLCJjbGllbnRfeDUwOV9jZXJ0X3VybCI6Imh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL3JvYm90L3YxL21ldGFkYXRhL3g1MDkvc3ltYm9sLWZpbm9wcyU0MGFjbWUtYmlsbGluZy5pYW0uZ3NlcnZpY2VhY2NvdW50LmNvbSIsInVuaXZlcnNlX2RvbWFpbiI6Imdvb2dsZWFwaXMuY29tIn0="
    valid_after  = "2026-10-22T09:00:00Z"
    valid_before = "9999-12-31T23:59:59Z"
  }
}

override_resource {
  target = module.identity[0].google_service_account_key.this["observability"]
  values = {
    name         = "projects/acme-billing/serviceAccounts/symbol-observability@acme-billing.iam.gserviceaccount.com/keys/fedcba9876543210fedcba9876543210fedcba98"
    private_key  = "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJvamVjdF9pZCI6ImFjbWUtYmlsbGluZyIsInByaXZhdGVfa2V5X2lkIjoiZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTBmZWRjYmE5OCIsInByaXZhdGVfa2V5IjoiZmFrZS1wcml2YXRlLWtleS1vZi1vYnNlcnZhYmlsaXR5LWZvci10ZXN0cyIsImNsaWVudF9lbWFpbCI6InN5bWJvbC1vYnNlcnZhYmlsaXR5QGFjbWUtYmlsbGluZy5pYW0uZ3NlcnZpY2VhY2NvdW50LmNvbSIsImNsaWVudF9pZCI6IjEwMDAwMDAwMDAwMDAwMDAwMDAwMiIsImF1dGhfdXJpIjoiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tL28vb2F1dGgyL2F1dGgiLCJ0b2tlbl91cmkiOiJodHRwczovL29hdXRoMi5nb29nbGVhcGlzLmNvbS90b2tlbiIsImF1dGhfcHJvdmlkZXJfeDUwOV9jZXJ0X3VybCI6Imh0dHBzOi8vd3d3Lmdvb2dsZWFwaXMuY29tL29hdXRoMi92MS9jZXJ0cyIsImNsaWVudF94NTA5X2NlcnRfdXJsIjoiaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20vcm9ib3QvdjEvbWV0YWRhdGEveDUwOS9zeW1ib2wtb2JzZXJ2YWJpbGl0eSU0MGFjbWUtYmlsbGluZy5pYW0uZ3NlcnZpY2VhY2NvdW50LmNvbSIsInVuaXZlcnNlX2RvbWFpbiI6Imdvb2dsZWFwaXMuY29tIn0="
    valid_after  = "2026-10-22T09:00:00Z"
    valid_before = "9999-12-31T23:59:59Z"
  }
}

variables {
  symbol_org_id           = "2"
  setup_session_id        = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  project_id              = "acme-billing"
  organization_id         = "987654321"
  billing_account_id      = "0123AB-CDEF45-6789AB"
  billing_export_detected = true
  create_focus_view       = true
  enable_finops           = true
  enable_monitoring       = true
  enable_security         = true
}

###############################################################################
# Connection code: exact schema (v2, keys included), every module combination
###############################################################################

run "all_modules_project_scope" {
  command = apply

  assert {
    condition     = startswith(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.") && !strcontains(nonsensitive(output.symbol_connection_code), "=") && !can(regex("[+/]", trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.")))
    error_message = "The code must be SYMBOL-GCP-2. + unpadded base64url."
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.")) % 4) % 4)))) == {
      v               = 2
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v2.0.2"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      modules         = ["finops", "monitoring", "security"]
      key = {
        finops = {
          service_account = "symbol-finops@acme-billing.iam.gserviceaccount.com"
          key_id          = "0123456789abcdef0123456789abcdef01234567"
          valid_after     = "2026-10-22T09:00:00Z"
          valid_before    = "9999-12-31T23:59:59Z"
          credentials = {
            type                        = "service_account"
            project_id                  = "acme-billing"
            private_key_id              = "0123456789abcdef0123456789abcdef01234567"
            private_key                 = "fake-private-key-of-finops-for-tests"
            client_email                = "symbol-finops@acme-billing.iam.gserviceaccount.com"
            client_id                   = "100000000000000000001"
            auth_uri                    = "https://accounts.google.com/o/oauth2/auth"
            token_uri                   = "https://oauth2.googleapis.com/token"
            auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
            client_x509_cert_url        = "https://www.googleapis.com/robot/v1/metadata/x509/symbol-finops%40acme-billing.iam.gserviceaccount.com"
            universe_domain             = "googleapis.com"
          }
        }
        observability = {
          service_account = "symbol-observability@acme-billing.iam.gserviceaccount.com"
          key_id          = "fedcba9876543210fedcba9876543210fedcba98"
          valid_after     = "2026-10-22T09:00:00Z"
          valid_before    = "9999-12-31T23:59:59Z"
          credentials = {
            type                        = "service_account"
            project_id                  = "acme-billing"
            private_key_id              = "fedcba9876543210fedcba9876543210fedcba98"
            private_key                 = "fake-private-key-of-observability-for-tests"
            client_email                = "symbol-observability@acme-billing.iam.gserviceaccount.com"
            client_id                   = "100000000000000000002"
            auth_uri                    = "https://accounts.google.com/o/oauth2/auth"
            token_uri                   = "https://oauth2.googleapis.com/token"
            auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
            client_x509_cert_url        = "https://www.googleapis.com/robot/v1/metadata/x509/symbol-observability%40acme-billing.iam.gserviceaccount.com"
            universe_domain             = "googleapis.com"
          }
        }
      }
      finops = {
        project_id              = "acme-billing"
        dataset                 = "billing_export"
        table                   = "gcp_focus_v1"
        billing_account_id      = "0123AB-CDEF45-6789AB"
        billing_export_detected = true
        focus_view_created      = true
      }
      observability = {
        project_id          = "acme-billing"
        subscription_id     = "projects/acme-billing/subscriptions/symbol-monitoring-sub"
        scc_subscription_id = null
        audit_scope_type    = "project"
        audit_scope_id      = "acme-billing"
      }
    }
    error_message = "The decoded code does not match contract §5.7 (v2) exactly."
  }

  assert {
    condition     = module.identity[0].service_account_ids == { finops = "symbol-finops", observability = "symbol-observability" }
    error_message = "Service account ids must be symbol-finops / symbol-observability (contract §5.7)."
  }

  assert {
    condition     = module.identity[0].rotation_ids == { finops = "initial", observability = "initial" }
    error_message = "Without key_rotation_ids every key is the 'initial' one."
  }

  assert {
    condition     = module.key_policy.policy_state == { "iam.disableServiceAccountKeyCreation" = "not_enforced", "iam.managed.disableServiceAccountKeyCreation" = "not_enforced" } && module.key_policy.exception_created == false
    error_message = "Both key-creation constraints are read; no exception is created when none is enforced."
  }

  assert {
    condition = toset(module.finops[0].iam_grants) == toset([
      { target = "dataset:acme-billing.billing_export", role = "roles/bigquery.dataViewer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/bigquery.jobUser", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/serviceusage.serviceUsageConsumer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/browser", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/compute.viewer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/recommender.viewer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/cloudasset.viewer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/storage.bucketViewer", member = "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com" },
    ])
    error_message = "FinOps grants (project scope) differ from contract section 5.6."
  }

  assert {
    condition     = strcontains(module.finops[0].focus_view.query, "FROM `acme-billing.billing_export.gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB`")
    error_message = "The FOCUS view must read the detailed export table of the billing account."
  }

  assert {
    condition     = module.finops[0].dataset == null
    error_message = "The dataset is not created when create_dataset = false."
  }

  assert {
    condition = toset(keys(module.finops[0].enabled_services)) == toset([
      "bigquery.googleapis.com", "cloudasset.googleapis.com", "cloudbilling.googleapis.com", "cloudresourcemanager.googleapis.com",
      "compute.googleapis.com", "recommender.googleapis.com", "serviceusage.googleapis.com", "storage.googleapis.com",
    ]) && alltrue([for k, v in module.finops[0].enabled_services : v.disable_on_destroy == false && v.project == "acme-billing"])
    error_message = "FinOps APIs must be enabled in project_id with disable_on_destroy = false."
  }

  assert {
    condition = toset(module.security[0].iam_grants) == toset([
      { target = "projects/acme-billing", role = "roles/viewer", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/iam.securityReviewer", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/cloudasset.viewer", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/storage.bucketViewer", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" },
    ])
    error_message = "Security roles must go to the observability identity."
  }

  assert {
    condition     = module.monitoring[0].sink == { parent = "projects/acme-billing", filter = "logName:\"cloudaudit.googleapis.com\"", destination = "pubsub.googleapis.com/projects/acme-billing/topics/symbol-monitoring", include_children = false, unique_writer_identity = true }
    error_message = "Project scope: a project sink with the audit-log filter and a unique writer identity."
  }

  assert {
    condition = toset(module.monitoring[0].iam_grants) == toset([
      { target = "topics/symbol-monitoring", role = "roles/pubsub.publisher", member = "serviceAccount:service-123456789012@gcp-sa-logging.iam.gserviceaccount.com" },
      { target = "subscriptions/symbol-monitoring-sub", role = "roles/pubsub.subscriber", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" },
    ])
    error_message = "Pub/Sub grants: sink writer identity publishes, observability identity subscribes, nothing else."
  }

  assert {
    condition     = module.monitoring[0].subscription_settings == { ack_deadline_seconds = 60, message_retention_duration = "604800s" }
    error_message = "Subscription: ack deadline 60 s, retention 7 days."
  }

  assert {
    condition     = strcontains(module.finops[0].focus_view.query, "\"0123AB-CDEF45-6789AB\" AS BillingAccountId") && module.finops[0].focus_view.use_legacy_sql == false
    error_message = "The FOCUS view must read the detailed export table of the billing account, in standard SQL."
  }

  assert {
    condition     = module.finops[0].focus_view.deletion_protection == false && module.finops[0].focus_view.table_id == "gcp_focus_v1" && module.finops[0].focus_view.dataset_id == "billing_export"
    error_message = "The view must be gcp_focus_v1 and destroyable."
  }

  assert {
    condition     = local.labels == { "symbol-managed" = "true", "symbol-org" = "2", "symbol-template" = "gcp-v2-0-2" }
    error_message = "Labels must be valid GCP label values."
  }

  assert {
    condition     = !strcontains(output.symbol_connection_summary, "fake-private-key") && strcontains(output.symbol_connection_summary, "(key 0123456789abcdef0123456789abcdef01234567)")
    error_message = "The summary names the key ids and never carries a key."
  }
}

run "reveal_all_modules_project_scope" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.all_modules_project_scope.symbol_connection_code
  }
}

run "finops_only" {
  command = apply

  variables {
    enable_monitoring = false
    enable_security   = false
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.")) % 4) % 4)))) == {
      v               = 2
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v2.0.2"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      modules         = ["finops"]
      key = {
        finops = {
          service_account = "symbol-finops@acme-billing.iam.gserviceaccount.com"
          key_id          = "0123456789abcdef0123456789abcdef01234567"
          valid_after     = "2026-10-22T09:00:00Z"
          valid_before    = "9999-12-31T23:59:59Z"
          credentials = {
            type                        = "service_account"
            project_id                  = "acme-billing"
            private_key_id              = "0123456789abcdef0123456789abcdef01234567"
            private_key                 = "fake-private-key-of-finops-for-tests"
            client_email                = "symbol-finops@acme-billing.iam.gserviceaccount.com"
            client_id                   = "100000000000000000001"
            auth_uri                    = "https://accounts.google.com/o/oauth2/auth"
            token_uri                   = "https://oauth2.googleapis.com/token"
            auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
            client_x509_cert_url        = "https://www.googleapis.com/robot/v1/metadata/x509/symbol-finops%40acme-billing.iam.gserviceaccount.com"
            universe_domain             = "googleapis.com"
          }
        }
        observability = null
      }
      finops = {
        project_id              = "acme-billing"
        dataset                 = "billing_export"
        table                   = "gcp_focus_v1"
        billing_account_id      = "0123AB-CDEF45-6789AB"
        billing_export_detected = true
        focus_view_created      = true
      }
      observability = null
    }
    error_message = "Disabled modules (and the unused identity) must be null."
  }

  assert {
    condition     = keys(module.identity[0].service_account_ids) == ["finops"]
    error_message = "Only symbol-finops is created when Monitoring and Security are off."
  }
}

run "reveal_finops_only" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.finops_only.symbol_connection_code
  }
}

run "monitoring_only_no_finops_identity" {
  command = apply

  variables {
    enable_finops     = false
    enable_security   = false
    create_focus_view = false
  }

  assert {
    condition     = keys(module.identity[0].service_account_ids) == ["observability"]
    error_message = "Only symbol-observability is created when FinOps is off."
  }

  assert {
    condition     = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.")) % 4) % 4)))).key.finops == null && jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(nonsensitive(output.symbol_connection_code), "SYMBOL-GCP-2.")) % 4) % 4)))).key.observability.key_id == "fedcba9876543210fedcba9876543210fedcba98"
    error_message = "Monitoring-only code: no FinOps key, the observability key."
  }

  assert {
    condition     = local.connection.modules == ["monitoring"] && local.connection.finops == null && local.connection.observability.subscription_id == "projects/acme-billing/subscriptions/symbol-monitoring-sub"
    error_message = "Monitoring-only code is wrong."
  }
}

run "reveal_monitoring_only_no_finops_identity" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.monitoring_only_no_finops_identity.symbol_connection_code
  }
}

run "security_only_folder_scope" {
  command = apply

  variables {
    enable_finops     = false
    enable_monitoring = false
    create_focus_view = false
    scope_type        = "folder"
    scope_id          = "555"
  }

  assert {
    condition     = length(module.security[0].iam_grants) == 4 && alltrue([for g in module.security[0].iam_grants : g.target == "folders/555"])
    error_message = "Folder scope: security grants on folders/555 only."
  }

  assert {
    condition     = local.connection.observability == { project_id = "acme-billing", subscription_id = null, scc_subscription_id = null, audit_scope_type = "folder", audit_scope_id = "555" } && local.connection.scope == { type = "folder", id = "555" } && local.connection.modules == ["security"]
    error_message = "Security-only folder code is wrong."
  }
}

run "reveal_security_only_folder_scope" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.security_only_folder_scope.symbol_connection_code
  }
}

run "organization_scope_with_scc" {
  command = apply

  variables {
    scope_type = "organization"
    scope_id   = "987654321"
    enable_scc = true
  }

  assert {
    condition     = module.monitoring[0].sink.parent == "organizations/987654321" && module.monitoring[0].sink.include_children
    error_message = "Organization scope: one organisation sink including children."
  }

  assert {
    condition     = contains(module.monitoring[0].iam_grants, { target = "topics/symbol-monitoring", role = "roles/pubsub.publisher", member = "serviceAccount:service-org-987654321@gcp-sa-logging.iam.gserviceaccount.com" })
    error_message = "The org sink writer identity must publish to the topic."
  }

  assert {
    condition     = module.monitoring[0].scc_organization == "987654321" && contains(module.monitoring[0].iam_grants, { target = "topics/symbol-scc", role = "roles/pubsub.publisher", member = "serviceAccount:service-org-987654321@gcp-sa-scc-notification.iam.gserviceaccount.com" }) && contains(module.monitoring[0].iam_grants, { target = "subscriptions/symbol-scc-sub", role = "roles/pubsub.subscriber", member = "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com" })
    error_message = "SCC notification config and its publisher grant are wrong."
  }

  assert {
    condition     = local.connection.observability.scc_subscription_id == "projects/acme-billing/subscriptions/symbol-scc-sub" && local.connection.observability.audit_scope_type == "organization" && local.connection.observability.audit_scope_id == "987654321"
    error_message = "SCC subscription and audit scope must be in the code."
  }

  assert {
    condition     = length([for g in module.finops[0].iam_grants : g if g.target == "organizations/987654321"]) == 5 && length([for g in module.security[0].iam_grants : g if g.target == "organizations/987654321"]) == 4
    error_message = "Organization scope: FinOps and security grants on the organisation."
  }
}

run "reveal_organization_scope_with_scc" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.organization_scope_with_scc.symbol_connection_code
  }
}

run "folder_scope_sink" {
  command = plan

  variables {
    scope_type = "folder"
    scope_id   = "555"
  }

  assert {
    condition     = module.monitoring[0].sink.parent == "folders/555" && module.monitoring[0].sink.include_children
    error_message = "Folder scope: one folder sink including children."
  }

  assert {
    condition     = length([for g in module.finops[0].iam_grants : g if g.target == "folders/555"]) == 5
    error_message = "Folder scope: FinOps scope grants on the folder."
  }
}

run "dataset_created_without_export" {
  command = apply

  variables {
    create_dataset          = true
    billing_export_detected = false
    create_focus_view       = false
    billing_account_id      = ""
  }

  assert {
    condition     = module.finops[0].dataset == { location = "US", delete_contents_on_destroy = false } && module.finops[0].focus_view == null
    error_message = "Dataset created in US, contents kept on destroy, no view without the export."
  }

  assert {
    condition     = local.connection.finops.billing_account_id == null && local.connection.finops.billing_export_detected == false && local.connection.finops.focus_view_created == false
    error_message = "finops block must report the missing export."
  }

  # Warning only.
  expect_failures = [check.billing_export]
}

run "reveal_dataset_created_without_export" {
  module {
    source = "./tests/reveal"
  }
  variables {
    code = run.dataset_created_without_export.symbol_connection_code
  }
}

###############################################################################
# Key rotation: only the identity whose rotation id changes gets a new key
###############################################################################

run "rotation_ids_reach_the_keys" {
  command = plan

  variables {
    key_rotation_ids = { finops = "8e3c3a6a-1f1e-4b8e-9d6e-0a1b2c3d4e5f" }
  }

  assert {
    condition     = module.identity[0].rotation_ids == { finops = "8e3c3a6a-1f1e-4b8e-9d6e-0a1b2c3d4e5f", observability = "initial" }
    error_message = "A rotation id replaces that identity's key only."
  }
}

###############################################################################
# Organisation policy: key creation forbidden, exception, unreadable, no organisation
###############################################################################

run "key_creation_forbidden_stops_the_plan" {
  command = plan

  override_data {
    target = module.key_policy.data.http.effective_policy["iam.managed.disableServiceAccountKeyCreation"]
    values = {
      status_code   = 200
      response_body = "{\"spec\":{\"rules\":[{\"enforce\":true}]}}"
    }
  }

  expect_failures = [terraform_data.key_creation_gate]
}

run "legacy_constraint_also_stops_the_plan" {
  command = plan

  override_data {
    target = module.key_policy.data.http.effective_policy["iam.disableServiceAccountKeyCreation"]
    values = {
      status_code   = 200
      response_body = "{\"spec\":{\"inheritFromParent\":true,\"rules\":[{\"enforce\":true}]}}"
    }
  }

  expect_failures = [terraform_data.key_creation_gate]
}

run "exception_lifts_both_constraints_for_this_project" {
  command = apply

  variables {
    allow_key_creation_exception = true
  }

  override_data {
    target = module.key_policy.data.http.effective_policy["iam.managed.disableServiceAccountKeyCreation"]
    values = {
      status_code   = 200
      response_body = "{\"spec\":{\"rules\":[{\"enforce\":true}]}}"
    }
  }

  assert {
    condition     = module.key_policy.exception_created && module.key_policy.ready.exception == tolist(["projects/acme-billing/policies/iam.disableServiceAccountKeyCreation", "projects/acme-billing/policies/iam.managed.disableServiceAccountKeyCreation"]) && length(module.key_policy.ready.waited) == 1
    error_message = "With the exception requested, both constraints are lifted on this project, then the keys wait for propagation."
  }

  assert {
    condition     = strcontains(output.symbol_connection_summary, "Key-creation policy exception: projects/acme-billing")
    error_message = "The summary says an exception was created."
  }
}

run "unreadable_policy_only_warns" {
  command = plan

  override_data {
    target = module.key_policy.data.http.effective_policy["iam.managed.disableServiceAccountKeyCreation"]
    values = {
      status_code   = 403
      response_body = "{\"error\":{\"code\":403,\"status\":\"PERMISSION_DENIED\"}}"
    }
  }

  assert {
    condition     = module.key_policy.unreadable == tolist(["iam.managed.disableServiceAccountKeyCreation"]) && length(module.key_policy.enforced) == 0
    error_message = "A policy that cannot be read is reported, not treated as enforced."
  }

  expect_failures = [check.key_creation_policy_readable]
}

run "no_organisation_reads_no_policy" {
  command = plan

  variables {
    organization_id              = ""
    allow_key_creation_exception = true
  }

  assert {
    condition     = module.key_policy.policy_state == {} && module.key_policy.exception_created == false
    error_message = "A project without organisation has no organisation policy: nothing is read or created."
  }
}

run "destroy_mode_reads_no_policy" {
  command = plan

  variables {
    destroy_mode = true
  }

  override_data {
    target = module.key_policy.data.http.effective_policy["iam.managed.disableServiceAccountKeyCreation"]
    values = {
      status_code   = 200
      response_body = "{\"spec\":{\"rules\":[{\"enforce\":true}]}}"
    }
  }

  assert {
    condition     = module.key_policy.policy_state == {}
    error_message = "destroy_mode must not read (or depend on) the organisation policies: revoking always works."
  }
}

###############################################################################
# Cross-variable rules (preflight)
###############################################################################

run "no_module_fails" {
  command = plan
  variables {
    enable_finops     = false
    enable_monitoring = false
    enable_security   = false
    create_focus_view = false
  }
  expect_failures = [terraform_data.preflight]
}

run "folder_scope_without_id_fails" {
  command = plan
  variables {
    scope_type = "folder"
  }
  expect_failures = [terraform_data.preflight]
}

run "org_scope_other_org_fails" {
  command = plan
  variables {
    scope_type = "organization"
    scope_id   = "111"
  }
  expect_failures = [terraform_data.preflight]
}

run "no_org_only_project_scope" {
  command = plan
  variables {
    organization_id = ""
    scope_type      = "folder"
    scope_id        = "555"
  }
  expect_failures = [terraform_data.preflight]
}

run "scc_needs_org_scope" {
  command = plan
  variables {
    enable_scc = true
  }
  expect_failures = [terraform_data.preflight]
}

run "focus_view_needs_export" {
  command = plan
  variables {
    billing_export_detected = false
  }
  expect_failures = [terraform_data.preflight, check.billing_export]
}

###############################################################################
# Variable validation
###############################################################################

run "bad_org_id" {
  command = plan
  variables {
    symbol_org_id = "org with space"
  }
  expect_failures = [var.symbol_org_id]
}

run "bad_session" {
  command = plan
  variables {
    setup_session_id = "not-a-uuid"
  }
  expect_failures = [var.setup_session_id]
}

run "bad_template" {
  command = plan
  variables {
    template_version = "oci-v1.0.0"
  }
  expect_failures = [var.template_version]
}

run "bad_project" {
  command = plan
  variables {
    project_id = "Acme_Billing"
  }
  expect_failures = [var.project_id]
}

run "bad_rotation_identity" {
  command = plan
  variables {
    key_rotation_ids = { signin = "x" }
  }
  expect_failures = [var.key_rotation_ids]
}

run "bad_rotation_value" {
  command = plan
  variables {
    key_rotation_ids = { finops = "a b" }
  }
  expect_failures = [var.key_rotation_ids]
}

run "bad_billing_account" {
  command = plan
  variables {
    billing_account_id = "0123ab-cdef45-6789ab"
  }
  expect_failures = [var.billing_account_id]
}

run "bad_scope_type" {
  command = plan
  variables {
    scope_type = "billing_account"
  }
  expect_failures = [var.scope_type]
}

run "bad_scope_id" {
  command = plan
  variables {
    scope_type = "folder"
    scope_id   = "folders/555"
  }
  expect_failures = [var.scope_id]
}

run "bad_dataset" {
  command = plan
  variables {
    billing_dataset = "billing-export"
  }
  expect_failures = [var.billing_dataset]
}

run "bad_egress_cidr" {
  command = plan
  variables {
    symbol_egress_cidrs = ["203.0.113.10"]
  }
  expect_failures = [var.symbol_egress_cidrs]
}
