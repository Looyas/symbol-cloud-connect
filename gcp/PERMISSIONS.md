# Permissions (gcp-v1.0.0)

Two parts: what **you** (the administrator running `symbol-setup.sh`) need, and what
**Symbol** receives. Every grant is a `google_*_iam_member` (additive): no existing
binding or policy is ever replaced, and destroy removes exactly the members it added.

"FinOps identity" and "observability identity" are, depending on the identity mode:

| | `symbol_principal` | `key_upload` |
|---|---|---|
| FinOps identity | `sym-<org>-fin@<symbol-project>.iam.gserviceaccount.com` (Symbol-owned, dedicated to your Symbol organisation) | `symbol-finops@<project>.iam.gserviceaccount.com` |
| Observability identity | `sym-<org>-obs@<symbol-project>.iam.gserviceaccount.com` | `symbol-observability@<project>.iam.gserviceaccount.com` |

## 1. What the administrator needs

`roles/owner` on the project covers every project-level line below. The table gives the
least-privilege alternative.

### Always (project `<project>`)

| Role | Why |
|---|---|
| `roles/serviceusage.serviceUsageAdmin` | Enable the APIs (script step 3 and `google_project_service`). Also gives `serviceusage.services.use`: the provider bills every call to the project (`user_project_override`). |
| `roles/storage.admin` | Create and configure the state bucket `gs://<project>-symbol-tfstate`, read/write the state. |
| `roles/resourcemanager.projectIamAdmin` | Add the project-level `iam_member` grants (and the scope grants with `--scope project`). |
| `roles/browser` (or any role with `resourcemanager.projects.get`) | Read the project, its ancestors and billing info. |

### Per module

| Module | Role (on the project unless stated) | Why |
|---|---|---|
| finops | `roles/bigquery.admin` (or `roles/bigquery.dataOwner` on the dataset + `bigquery.datasets.create`) | Create the dataset if absent, create the view, add the dataset grant |
| finops | `roles/billing.viewer` on the billing account (optional) | Only to show the billing account in the summary; detection works from the table name without it |
| monitoring | `roles/pubsub.admin` | Topics, subscriptions, their IAM members |
| monitoring | `roles/logging.configWriter` (at the scope: project, folder or organisation) | Create the `symbol-audit-sink` |
| monitoring + `--scc` | `roles/securitycenter.notificationConfigEditor` on the organisation | Create the SCC notification config |
| key_upload | `roles/iam.serviceAccountAdmin` and `roles/iam.serviceAccountKeyAdmin` | Create `symbol-finops` / `symbol-observability` and upload Symbol's certificates |

### Per scope

| Scope | Extra role | Why |
|---|---|---|
| `project` | - | |
| `folder:<id>` | `roles/resourcemanager.folderIamAdmin` on the folder; `roles/logging.configWriter` on the folder | Folder grants, folder sink |
| `organization:<id>` | `roles/resourcemanager.organizationAdmin` on the organisation (for `setIamPolicy`); `roles/logging.configWriter` on the organisation | Organisation grants, organisation sink |

### Org-policy detection (optional)

`orgpolicy.policy.get` (e.g. `roles/orgpolicy.policyViewer` on the organisation). Without
it the script cannot read the effective policies; in `auto` mode it then tries
`symbol_principal` and says so.

## 2. What Symbol receives

### finops: FinOps identity

| Role | On | Why (Symbol consumer) |
|---|---|---|
| `roles/bigquery.dataViewer` | dataset `<project>.billing_export` | Read `gcp_focus_v1` and the export table it selects from (same dataset, so no authorized view is needed) - ingestion-service |
| `roles/bigquery.jobUser` | project `<project>` | Run the ingestion queries; **jobs are billed to your project** |
| `roles/serviceusage.serviceUsageConsumer` | project `<project>` | `serviceusage.services.use`: every Symbol call sets `<project>` as quota project (`x-goog-user-project`), in both identity modes |
| `roles/browser` | scope | List/get projects and folders (budget scopes, billing info, hierarchy) - budget-system, cloud-api-rec |
| `roles/compute.viewer` | scope | Instances, disks, addresses, zones/regions - inventory-collector, cloud-api-rec |
| `roles/recommender.viewer` | scope | `get`/`list` on every project-level recommender and insight, including cost (`cloudCostGeneral*`) and CUD (`usageCommitment*`, `spendBasedCommitment*`) - cloud-api-rec ([role reference](https://cloud.google.com/iam/docs/roles-permissions/recommender)) |
| `roles/cloudasset.viewer` | scope | `searchAllResources` inventory |
| `roles/storage.bucketViewer` | scope | `storage.buckets.get` / `storage.buckets.list` only: bucket metadata for inventory-collector. No object listing or reading, no bucket IAM policy. Google lists this role as Beta ([role reference](https://cloud.google.com/iam/docs/roles-permissions/storage)) |

APIs enabled in `<project>` (with `disable_on_destroy = false`, never switched off):
`bigquery`, `cloudasset`, `cloudbilling`, `cloudresourcemanager`, `compute`,
`recommender`, `serviceusage`, `storage` (`.googleapis.com`). Because every call uses
`<project>` as quota project, these must be enabled **there**, whatever the scope.

Billing-account level CUD recommendations (`roles/recommender.billingAccountCudViewer`,
granted on a billing account) are **not** granted: Symbol v1 reads project-level
recommenders only.

### monitoring: observability identity

| Role | On | Why |
|---|---|---|
| `roles/pubsub.subscriber` | subscription `symbol-monitoring-sub` | Consume audit-log events (StreamingPull, ack) - monitoring-service |
| `roles/pubsub.subscriber` | subscription `symbol-scc-sub` (`--scc` only) | Consume SCC findings |

Grants to Google-managed service agents (not to Symbol):

| Member | Role | On |
|---|---|---|
| The sink's `writer_identity` (`service-<n>@gcp-sa-logging.iam.gserviceaccount.com`) | `roles/pubsub.publisher` | topic `symbol-monitoring` |
| The SCC notification's `service_account` | `roles/pubsub.publisher` | topic `symbol-scc` |

The sink filter is `logName:"cloudaudit.googleapis.com"`: Admin Activity, System Event,
Policy Denied and (if you enabled them) Data Access audit logs. No Symbol identity can
publish to the topics.

### security: observability identity, at the scope

| Role | Why (Security-agent-scanner, CIS GCP checks) |
|---|---|
| `roles/viewer` | Read the configuration of compute, storage, logging, BigQuery, networking, KMS, SQL, GKE resources |
| `roles/iam.securityReviewer` | List and read every IAM allow policy (`getIamPolicy` on all resource types) |
| `roles/cloudasset.viewer` | `searchAllResources`, `searchAllIamPolicies` across the scope |

### key_upload only

| Object | Setting |
|---|---|
| `symbol-finops`, `symbol-observability` service accounts | No role other than the grants above; no `iam.serviceAccountUser` / token creator for anyone |
| One key each | `public_key_data` = base64 of Symbol's session certificate (RSA-2048, X.509, 2 years). No private key is ever created in GCP or present in Terraform state |

## Notes

- `roles/viewer` is a **basic** role and the broadest grant here. Besides configuration
  it can include data reads in some services (for example BigQuery datasets whose ACL
  gives READER to project viewers, which is the default). It is required by the
  contract for the scanner's coverage; replacing it with a custom read-only role is a
  hardening candidate for a later version.
- `symbol_egress_cidrs` is not used: GCP IAM has no per-principal source-IP condition
  outside VPC Service Controls access levels, which this template does not create.
  In `symbol_principal` mode the principals cannot be used outside Symbol (no key exists).
