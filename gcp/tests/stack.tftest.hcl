# Offline tests with mocked providers (no GCP project, no credentials).
# Requires Terraform >= 1.7 (mock providers).
#   terraform init -backend=false && terraform test
#
# Every run that checks the connection code decodes it exactly like Symbol's decoder:
# strip the prefix, base64url -> standard alphabet, re-pad, base64decode, jsondecode;
# then compares the WHOLE object, so any extra, missing or renamed key fails (§5.7).

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
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

mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUTest+/=\n-----END CERTIFICATE-----\n"
    }
  }
}

# Service accounts and keys created in key_upload mode: deterministic e-mails and key ids.
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
    name = "projects/acme-billing/serviceAccounts/symbol-finops@acme-billing.iam.gserviceaccount.com/keys/0123456789abcdef0123456789abcdef01234567"
  }
}

override_resource {
  target = module.identity[0].google_service_account_key.this["observability"]
  values = {
    name = "projects/acme-billing/serviceAccounts/symbol-observability@acme-billing.iam.gserviceaccount.com/keys/fedcba9876543210fedcba9876543210fedcba98"
  }
}

variables {
  symbol_org_id           = "2"
  setup_session_id        = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  project_id              = "acme-billing"
  organization_id         = "987654321"
  identity_mode           = "symbol_principal"
  finops_principal        = "sym-2-fin@symbol-prod.iam.gserviceaccount.com"
  observability_principal = "sym-2-obs@symbol-prod.iam.gserviceaccount.com"
  billing_account_id      = "0123AB-CDEF45-6789AB"
  billing_export_detected = true
  create_focus_view       = true
  enable_finops           = true
  enable_monitoring       = true
  enable_security         = true
}

###############################################################################
# Connection code: exact schema, both identity modes, every module combination
###############################################################################

run "principal_all_modules_project_scope" {
  command = apply

  assert {
    condition     = startswith(output.symbol_connection_code, "SYMBOL-GCP-1.") && !strcontains(output.symbol_connection_code, "=") && !can(regex("[+/]", trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1.")))
    error_message = "The code must be SYMBOL-GCP-1. + unpadded base64url."
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1.")) % 4) % 4)))) == {
      v               = 1
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v1.0.0"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      identity_mode   = "symbol_principal"
      modules         = ["finops", "monitoring", "security"]
      principals = {
        finops        = "sym-2-fin@symbol-prod.iam.gserviceaccount.com"
        observability = "sym-2-obs@symbol-prod.iam.gserviceaccount.com"
      }
      key = null
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
    error_message = "The decoded code does not match contract §5.7 exactly."
  }

  assert {
    condition     = length(module.identity) == 0
    error_message = "symbol_principal mode must not create service accounts or keys."
  }

  assert {
    condition = toset(module.finops[0].iam_grants) == toset([
      { target = "dataset:acme-billing.billing_export", role = "roles/bigquery.dataViewer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/bigquery.jobUser", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/serviceusage.serviceUsageConsumer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/browser", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/compute.viewer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/recommender.viewer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/cloudasset.viewer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/storage.bucketViewer", member = "serviceAccount:sym-2-fin@symbol-prod.iam.gserviceaccount.com" },
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
      { target = "projects/acme-billing", role = "roles/viewer", member = "serviceAccount:sym-2-obs@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/iam.securityReviewer", member = "serviceAccount:sym-2-obs@symbol-prod.iam.gserviceaccount.com" },
      { target = "projects/acme-billing", role = "roles/cloudasset.viewer", member = "serviceAccount:sym-2-obs@symbol-prod.iam.gserviceaccount.com" },
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
      { target = "subscriptions/symbol-monitoring-sub", role = "roles/pubsub.subscriber", member = "serviceAccount:sym-2-obs@symbol-prod.iam.gserviceaccount.com" },
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
    condition     = local.labels == { "symbol-managed" = "true", "symbol-org" = "2", "symbol-template" = "gcp-v1-0-0" }
    error_message = "Labels must be valid GCP label values."
  }
}

run "key_upload_all_modules" {
  command = apply

  variables {
    identity_mode                 = "key_upload"
    finops_principal              = ""
    observability_principal       = ""
    finops_certificate_url        = "https://platform.example.com/api/cloud-connections/setup/public/sessions/3f2504e0-4f89-41d3-9a0c-0305e82c3301/keys/finops.crt"
    observability_certificate_url = "https://platform.example.com/api/cloud-connections/setup/public/sessions/3f2504e0-4f89-41d3-9a0c-0305e82c3301/keys/observability.crt"
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1.")) % 4) % 4)))) == {
      v               = 1
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v1.0.0"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      identity_mode   = "key_upload"
      modules         = ["finops", "monitoring", "security"]
      principals      = null
      key = {
        finops        = { service_account = "symbol-finops@acme-billing.iam.gserviceaccount.com", key_id = "0123456789abcdef0123456789abcdef01234567" }
        observability = { service_account = "symbol-observability@acme-billing.iam.gserviceaccount.com", key_id = "fedcba9876543210fedcba9876543210fedcba98" }
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
    error_message = "key_upload code does not match contract §5.7 / §5.3."
  }

  assert {
    condition     = module.identity[0].public_key_data["finops"] == base64encode("-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUTest+/=\n-----END CERTIFICATE-----\n")
    error_message = "public_key_data must be the base64 of the certificate PEM."
  }

  assert {
    condition     = module.identity[0].service_account_ids == { finops = "symbol-finops", observability = "symbol-observability" } && toset(keys(data.http.certificate)) == toset(["finops", "observability"])
    error_message = "Service account ids must be symbol-finops / symbol-observability (contract §5.7 rule 6)."
  }

  assert {
    condition     = alltrue([for g in module.finops[0].iam_grants : g.member == "serviceAccount:symbol-finops@acme-billing.iam.gserviceaccount.com"]) && alltrue([for g in module.security[0].iam_grants : g.member == "serviceAccount:symbol-observability@acme-billing.iam.gserviceaccount.com"])
    error_message = "Grants must target the uploaded-key service accounts."
  }
}

run "finops_only" {
  command = apply

  variables {
    enable_monitoring = false
    enable_security   = false
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1.")) % 4) % 4)))) == {
      v               = 1
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v1.0.0"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      identity_mode   = "symbol_principal"
      modules         = ["finops"]
      principals      = { finops = "sym-2-fin@symbol-prod.iam.gserviceaccount.com", observability = null }
      key             = null
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
}

run "monitoring_only_key_upload_no_finops_identity" {
  command = apply

  variables {
    enable_finops                 = false
    enable_security               = false
    create_focus_view             = false
    identity_mode                 = "key_upload"
    observability_certificate_url = "https://platform.example.com/keys/observability.crt"
  }

  assert {
    condition     = keys(module.identity[0].service_account_ids) == ["observability"] && keys(data.http.certificate) == ["observability"]
    error_message = "Only symbol-observability is created when FinOps is off."
  }

  assert {
    condition = jsondecode(base64decode(format("%s%s", replace(replace(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1."), "-", "+"), "_", "/"), substr("===", 0, (4 - length(trimprefix(output.symbol_connection_code, "SYMBOL-GCP-1.")) % 4) % 4)))) == {
      v               = 1
      org             = "2"
      session         = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
      template        = "gcp-v1.0.0"
      project         = "acme-billing"
      project_number  = "123456789012"
      organization_id = "987654321"
      scope           = { type = "project", id = "acme-billing" }
      identity_mode   = "key_upload"
      modules         = ["monitoring"]
      principals      = null
      key = {
        finops        = null
        observability = { service_account = "symbol-observability@acme-billing.iam.gserviceaccount.com", key_id = "fedcba9876543210fedcba9876543210fedcba98" }
      }
      finops = null
      observability = {
        project_id          = "acme-billing"
        subscription_id     = "projects/acme-billing/subscriptions/symbol-monitoring-sub"
        scc_subscription_id = null
        audit_scope_type    = "project"
        audit_scope_id      = "acme-billing"
      }
    }
    error_message = "Monitoring-only key_upload code is wrong."
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
    condition     = length(module.security[0].iam_grants) == 3 && alltrue([for g in module.security[0].iam_grants : g.target == "folders/555"])
    error_message = "Folder scope: security grants on folders/555 only."
  }

  assert {
    condition     = local.connection.observability == { project_id = "acme-billing", subscription_id = null, scc_subscription_id = null, audit_scope_type = "folder", audit_scope_id = "555" } && local.connection.scope == { type = "folder", id = "555" } && local.connection.modules == ["security"]
    error_message = "Security-only folder code is wrong."
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
    condition     = module.monitoring[0].scc_organization == "987654321" && contains(module.monitoring[0].iam_grants, { target = "topics/symbol-scc", role = "roles/pubsub.publisher", member = "serviceAccount:service-org-987654321@gcp-sa-scc-notification.iam.gserviceaccount.com" }) && contains(module.monitoring[0].iam_grants, { target = "subscriptions/symbol-scc-sub", role = "roles/pubsub.subscriber", member = "serviceAccount:sym-2-obs@symbol-prod.iam.gserviceaccount.com" })
    error_message = "SCC notification config and its publisher grant are wrong."
  }

  assert {
    condition     = local.connection.observability.scc_subscription_id == "projects/acme-billing/subscriptions/symbol-scc-sub" && local.connection.observability.audit_scope_type == "organization" && local.connection.observability.audit_scope_id == "987654321"
    error_message = "SCC subscription and audit scope must be in the code."
  }

  assert {
    condition     = length([for g in module.finops[0].iam_grants : g if g.target == "organizations/987654321"]) == 5 && length([for g in module.security[0].iam_grants : g if g.target == "organizations/987654321"]) == 3
    error_message = "Organization scope: FinOps and security grants on the organisation."
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

run "destroy_mode_skips_downloads_and_checks" {
  command = plan

  variables {
    identity_mode           = "key_upload"
    finops_principal        = ""
    observability_principal = ""
    destroy_mode            = true
  }

  assert {
    condition     = length(data.http.certificate) == 0
    error_message = "destroy_mode must not download certificates (expired sessions answer 404)."
  }
}

###############################################################################
# Certificate download failures
###############################################################################

run "certificate_404_fails" {
  command = plan

  variables {
    identity_mode                 = "key_upload"
    finops_certificate_url        = "https://platform.example.com/keys/finops.crt"
    observability_certificate_url = "https://platform.example.com/keys/observability.crt"
  }

  override_data {
    target = data.http.certificate["finops"]
    values = {
      status_code   = 404
      response_body = "{\"detail\":\"not found\"}"
    }
  }

  expect_failures = [data.http.certificate["finops"]]
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

run "principal_mode_without_principal_fails" {
  command = plan
  variables {
    observability_principal = ""
  }
  expect_failures = [terraform_data.preflight]
}

run "same_principal_twice_fails" {
  command = plan
  variables {
    observability_principal = "sym-2-fin@symbol-prod.iam.gserviceaccount.com"
  }
  expect_failures = [terraform_data.preflight]
}

run "key_upload_without_certificate_url_fails" {
  command = plan
  variables {
    identity_mode = "key_upload"
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

run "bad_identity_mode" {
  command = plan
  variables {
    identity_mode = "json_key"
  }
  expect_failures = [var.identity_mode]
}

run "bad_principal" {
  command = plan
  variables {
    finops_principal = "someone@gmail.com"
  }
  expect_failures = [var.finops_principal]
}

run "http_certificate_url_rejected" {
  command = plan
  variables {
    finops_certificate_url = "http://platform.example.com/keys/finops.crt"
  }
  expect_failures = [var.finops_certificate_url]
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
