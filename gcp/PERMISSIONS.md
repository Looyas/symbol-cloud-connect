# Permissions (gcp-v2.0.0)

Two parts: what **you** (the administrator running `symbol-setup.sh`) need, and what
**Symbol** receives. Every grant is a `google_*_iam_member` (additive): no existing
binding or policy is ever replaced, and destroy removes exactly the members it added.

The two identities are service accounts the template creates **in your project**, each
with one Google-generated key held by Symbol:

| | Service account |
|---|---|
| FinOps identity | `symbol-finops@<project>.iam.gserviceaccount.com` |
| Observability identity | `symbol-observability@<project>.iam.gserviceaccount.com` |

## 1. What the administrator needs

`roles/owner` on the project covers every project-level line below. The table gives the
least-privilege alternative.

### Always (project `<project>`)

| Role | Why |
|---|---|
| `roles/serviceusage.serviceUsageAdmin` | Enable the APIs (script step 3 and `google_project_service`). Also gives `serviceusage.services.use`: the provider bills every call to the project (`user_project_override`). |
| `roles/storage.admin` | Create and configure the state bucket `gs://<project>-symbol-tfstate`, read/write the state. |
| `roles/resourcemanager.projectIamAdmin` | Add the project-level `iam_member` grants (and the scope grants with `--scope project`). |
| `roles/iam.serviceAccountAdmin` | Create `symbol-finops` / `symbol-observability`. |
| `roles/iam.serviceAccountKeyAdmin` | Create (and on rotation or destroy, delete) their keys. |
| `roles/browser` (or any role with `resourcemanager.projects.get`) | Read the project, its ancestors and billing info. |

### Per module

| Module | Role (on the project unless stated) | Why |
|---|---|---|
| finops | `roles/bigquery.admin` (or `roles/bigquery.dataOwner` on the dataset + `bigquery.datasets.create`) | Create the dataset if absent, create the view, add the dataset grant |
| finops | `roles/billing.viewer` on the billing account (optional) | Only to show the billing account in the summary; detection works from the table name without it |
| monitoring | `roles/pubsub.admin` | Topics, subscriptions, their IAM members |
| monitoring | `roles/logging.configWriter` (at the scope: project, folder or organisation) | Create the `symbol-audit-sink` |
| monitoring + `--scc` | `roles/securitycenter.notificationConfigEditor` on the organisation | Create the SCC notification config |

### Per scope

| Scope | Extra role | Why |
|---|---|---|
| `project` | - | |
| `folder:<id>` | `roles/resourcemanager.folderIamAdmin` on the folder; `roles/logging.configWriter` on the folder | Folder grants, folder sink |
| `organization:<id>` | `roles/resourcemanager.organizationAdmin` on the organisation (for `setIamPolicy`); `roles/logging.configWriter` on the organisation | Organisation grants, organisation sink |

### Organisation policy: service-account keys

| Need | Role | Why |
|---|---|---|
| Read the key-creation policy (recommended) | `roles/orgpolicy.policyViewer` on the organisation (`orgpolicy.policies.get`) | The script and the template read the **effective** `iam.disableServiceAccountKeyCreation` and `iam.managed.disableServiceAccountKeyCreation` on the project. Without it they warn and continue; Google's answer at key creation decides. |
| `--allow-key-creation-exception` only | `roles/orgpolicy.policyAdmin` on the **organisation** (the role cannot be granted lower) | The template creates `projects/<project>/policies/<constraint>` with `enforce: false` for both constraints, and `--destroy` deletes them. Nothing else is changed: the organisation keeps its policy for every other project. |

Without that role, an Organization Policy Administrator runs, once, for your project:

```bash
for c in iam.disableServiceAccountKeyCreation iam.managed.disableServiceAccountKeyCreation; do
  printf 'name: projects/<PROJECT>/policies/%s
spec:
  rules:
  - enforce: false
' "$c" > symbol-allow-keys.yaml
  gcloud org-policies set-policy symbol-allow-keys.yaml
done
```

Lifting it afterwards (`gcloud org-policies delete <constraint> --project=<PROJECT>`) does
not revoke keys that already exist; it only forbids creating new ones (a rotation would
then need the exception again).

## 2. What Symbol receives

### finops: FinOps identity

| Role | On | Why (Symbol consumer) |
|---|---|---|
| `roles/bigquery.dataViewer` | dataset `<project>.billing_export` | Read `gcp_focus_v1` and the export table it selects from (same dataset, so no authorized view is needed) - ingestion-service |
| `roles/bigquery.jobUser` | project `<project>` | Run the ingestion queries; **jobs are billed to your project** |
| `roles/serviceusage.serviceUsageConsumer` | project `<project>` | `serviceusage.services.use`: every Symbol call sets `<project>` as quota project (`x-goog-user-project`) |
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

### The identities themselves

| Object | Setting |
|---|---|
| `symbol-finops`, `symbol-observability` service accounts | No role other than the grants above; no `iam.serviceAccountUser` / Token Creator for anyone |
| One key each | Created by Google (`KEY_ALG_RSA_2048`, `TYPE_GOOGLE_CREDENTIALS_FILE`); delivered to Symbol in the connection code and kept in Symbol's vault; replaced only by `--rotate`; deleted by `--destroy` |

## Notes

- `roles/viewer` is a **basic** role and the broadest grant here. Besides configuration
  it can include data reads in some services (for example BigQuery datasets whose ACL
  gives READER to project viewers, which is the default). It is required by the
  contract for the scanner's coverage; replacing it with a custom read-only role is a
  hardening candidate for a later version.
- `symbol_egress_cidrs` is not used: GCP IAM has no per-principal source-IP condition
  outside VPC Service Controls access levels, which this template does not create.
  The keys are therefore usable from anywhere: keep the connection code secret, and
  delete a key at once (console) if you suspect it leaked.
