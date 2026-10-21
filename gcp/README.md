# Symbol Cloud Connect for GCP

Public Terraform template, plus the `symbol-setup.sh` script that runs it, connecting a
Google Cloud project (and optionally its folder or organisation) to Symbol. You run it
in **your own Cloud Shell**, with **your own** credentials. Symbol never receives an
administrator credential and no secret leaves your project: the only output is a
**connection code** made of identifiers, which you paste into Symbol.

| Module | What the template creates | Used by Symbol for |
|---|---|---|
| `finops` | APIs (BigQuery, Cloud Billing, Recommender, Cloud Asset, Compute, Resource Manager, Storage, Service Usage); dataset `billing_export` if absent; FOCUS view `gcp_focus_v1` over the detailed billing export; read grants | Cost ingestion, inventory, recommendations, budgets |
| `monitoring` | Pub/Sub topic `symbol-monitoring` + subscription `symbol-monitoring-sub`, log sink `symbol-audit-sink` (Cloud Audit Logs); optionally topic `symbol-scc`, subscription `symbol-scc-sub` and an SCC notification `symbol-scc` | Real-time audit events and SCC findings |
| `security` | Read-only grants at the chosen scope | CIS security scan |

Every role is listed, with its reason, in [PERMISSIONS.md](PERMISSIONS.md). The trust
model is in [SECURITY.md](SECURITY.md).

## Before you start: billing export (FinOps only)

Google offers **no API** to turn on the Cloud Billing export. Do it once, in the console:

1. **Billing > Billing export > BigQuery export** for your billing account
   (`https://console.cloud.google.com/billing/<BILLING_ACCOUNT_ID>/export`).
2. Enable **Detailed usage cost**, project = the project you will run the setup in,
   dataset = `billing_export` (create it there, or let the setup create it first and
   come back).

Data starts flowing a few hours later, with no history before that day. If the export
is not there yet, the setup still completes, prints the deep link above and the FOCUS
view is created when you run the same command again.

## How you get here

1. In Symbol: **Administration > Cloud configuration > GCP > Configure**. Pick the
   modules, the scope (project, folder or organisation) and **Automatic**.
2. Symbol creates a setup session, prepares the identities (see *Identity modes*) and
   shows a button **Open Cloud Shell** (`https://shell.cloud.google.com/?show=terminal`)
   and **one command** to copy. It looks like this:
   ```bash
   bash -c 'set -euo pipefail; d="$HOME/symbol-cloud-connect-1a2b3c4d"; rm -rf "$d";
   git clone --quiet --depth 1 --branch gcp-v1.0.0 https://github.com/Looyas/symbol-cloud-connect "$d";
   test "$(git -C "$d" rev-parse HEAD)" = "<commit>" || { echo "Template integrity check failed"; exit 1; };
   exec "$d/gcp/symbol-setup.sh" --org 2 --session <uuid> --template gcp-v1.0.0
     --modules finops,monitoring,security --identity-mode auto
     --finops-principal sym-2-fin@<symbol-project>.iam.gserviceaccount.com
     --observability-principal sym-2-obs@<symbol-project>.iam.gserviceaccount.com
     --cert-base-url https://<symbol>/api/cloud-connections/setup/public/sessions/<uuid>/keys
     --scope project'
   ```
   The clone is pinned to a **tag and its exact commit**: a moved tag or a tampered
   repository stops the command before anything runs.
3. Paste it into Cloud Shell, signed in as an administrator of the project
   ([PERMISSIONS.md](PERMISSIONS.md) lists the exact roles per scope).

## What `symbol-setup.sh` does

| Step | Action |
|---|---|
| 1 | Resolves the project: `--project`, else `gcloud config get-value project` (empty: it stops and tells you to run `gcloud config set project <ID>`). |
| 2 | Uses Terraform >= 1.5 if present; otherwise installs Terraform **1.16.6** into `~/.symbol/bin`, after checking the archive's SHA-256 against the value pinned in the script **and** HashiCorp's `SHA256SUMS`, whose GPG signature is verified against HashiCorp's key `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F` when `gpg` is available (it is in Cloud Shell). |
| 3 | Enables the bootstrap APIs (`serviceusage`, `cloudresourcemanager`, `iam`, `storage`, `bigquery`, `pubsub`, `logging`, `cloudasset`, `recommender`, `cloudbilling`; `orgpolicy` when the project is in an organisation). APIs are never disabled later. |
| 4 | Finds the organisation (`gcloud projects get-ancestors`) and reads the **effective** org policies on the project (`gcloud org-policies describe <constraint> --effective --project=<p>`, falling back to `gcloud resource-manager org-policies describe`), then picks the identity mode (below). |
| 5 | Detects billing: the project's billing account (`gcloud billing projects describe`), the dataset (`bq show`), the detailed export table `gcp_billing_export_resource_v1_<ACCOUNT>` and an existing `gcp_focus_v1`. If the dataset holds the export of another billing account, the table name wins. |
| 6 | Creates the state bucket `gs://<project>-symbol-tfstate` if absent (location `US` or `--state-location`, uniform bucket-level access, public access prevention enforced, versioning on) and runs `terraform init` with prefix `symbol-cloud-connect/<org>`. A bucket with that name owned by another project is refused. |
| 7 | `terraform plan -out symbol.tfplan` with every variable, shows the plan, asks **`Apply? [y/N]`** (`--yes` is for CI only), then applies the saved plan. The variables (no secret) are saved next to the state for a later `--destroy`. |
| 8 | Prints the **connection code** in a frame, a summary, and warnings (billing export missing, with the deep link; data not yet available). |

Copy the line `SYMBOL-GCP-1.…` and paste it into Symbol. Symbol validates it, then checks
every module **as the identity it just received** (BigQuery query, subscription
permissions, Cloud Asset probe) and shows a green checklist. IAM changes can take a few
minutes to propagate.

## Identity modes

| Mode | How Symbol authenticates | Created in your project | Blocked by |
|---|---|---|---|
| `symbol_principal` (preferred) | Roles are granted to **two service accounts owned by Symbol**, one per purpose (`sym-<org>-fin@…`, `sym-<org>-obs@…`), dedicated to your Symbol organisation. Symbol impersonates them; no key exists anywhere. | Nothing but grants | `iam.allowedPolicyMemberDomains` (domain restricted sharing) unless your allow-list contains Symbol's customer ID |
| `key_upload` (fallback) | Two service accounts **in your project**, `symbol-finops@<project>` and `symbol-observability@<project>`. Their only key is the **public certificate** Symbol generated for this session (`google_service_account_key.public_key_data`); the private key never leaves Symbol's Vault. | 2 service accounts, 2 uploaded keys | `iam.disableServiceAccountKeyUpload` or `iam.managed.disableServiceAccountKeyUpload` |

With `--identity-mode auto` (the default) the script uses `symbol_principal` unless the
effective `iam.allowedPolicyMemberDomains` list policy (or the managed
`iam.managed.allowedPolicyMemberDomains`) restricts members. The script cannot know
whether Symbol's customer ID is on your allow-list, so any restriction counts as blocking
and it switches to `key_upload` with a note. If key upload is also disabled it stops and
names both constraints. If the policies cannot be read (missing `orgpolicy.policy.get`),
it tries `symbol_principal` and says so. The code tells Symbol which mode was used.

## Scope

`--scope project` (default) grants inventory, recommendation and security read access
on the project and creates a **project** log sink. `--scope folder:<id>` and
`--scope organization:<id>` grant them on the folder or organisation and create a folder
or organisation sink with `include_children = true`. Dataset, BigQuery job and Pub/Sub
grants always stay on the project. `--scc` (organisation scope only) streams **active**
Security Command Center findings (SCC must already be activated).

## Revoking access (destroy)

```bash
~/symbol-cloud-connect-<session8>/gcp/symbol-setup.sh --destroy --org <org> [--project <project>]
```

Any project administrator can run it (state and variables live in
`gs://<project>-symbol-tfstate`; clone the same tag first if the directory is gone). It
plans the removal, asks `Destroy? [y/N]`, and removes every grant, the sink, the topics,
subscriptions, SCC notification, service accounts and their keys, and the FOCUS view.
It does **not** delete the billing dataset (your billing data; it is released from the
state first), the state bucket, or enable/disable any API. Certificates are not
downloaded during destroy, so it works after the setup session has expired.

In Symbol, **Disconnect** removes Symbol's side; in `symbol_principal` mode it also
disables your Symbol service accounts, which cuts access immediately even before you run
destroy.

## Updating

When Symbol shows *Update available*, it gives a new command with the new tag. Run it:
the plan shows only the differences (`google_*_iam_member` changes, a new key when the
certificate changes), and resources created by the earlier version (dataset, view) stay
managed. Releases are immutable and listed in [CHANGELOG.md](CHANGELOG.md).

## The FOCUS view `gcp_focus_v1`

Symbol reads `SELECT * FROM <project>.<dataset>.gcp_focus_v1 WHERE DATE(ChargePeriodStart) …`.
The view (`modules/finops/focus_view.sql.tftpl`) is Google's *BigQuery view for FOCUS v1.0
GA* adapted to the exact columns Symbol's reader consumes; each difference is commented
at the top of the SQL. It needs only the **detailed usage cost** export (not the Price
Export), so `ListUnitPrice` and `ServiceCategory` are `NULL`. It is a view: no storage
cost, no copy of your data.

## Repository layout

```
gcp/
  symbol-setup.sh                  Cloud Shell entry point (bash, shellcheck-clean)
  versions.tf providers.tf variables.tf main.tf outputs.tf .terraform.lock.hcl
  modules/finops                   APIs, dataset, FOCUS view, FinOps grants
  modules/monitoring               topics, subscriptions, sink, SCC notification
  modules/security                 scanner grants
  modules/identity                 key_upload service accounts and uploaded keys
  tests/stack.tftest.hcl           mocked Terraform tests (no GCP account)
  tests/test_code_schema.py        connection code vs contract §5.7, FOCUS columns, IAM
  tests/test_setup_script.py       symbol-setup.sh against stub gcloud/bq/terraform
```

Local checks (as in `.github/workflows/gcp-ci.yml`):

```bash
cd gcp
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test                                # Terraform >= 1.7
python3 -m pytest -q tests                    # needs pytest; uses terraform if on PATH
shellcheck -x symbol-setup.sh
```

Requirements: Terraform >= 1.5 (the script installs 1.16.6 when needed), providers
`hashicorp/google` 8.7.0 and `hashicorp/http` 3.6.2 (hashes in `.terraform.lock.hcl`).

## Not automated (by design or because no API exists)

- Enabling the Cloud Billing export (console only, see above).
- Activating Security Command Center (organisation level).
- Data Access audit logs (only Admin Activity / System Event / Policy Denied logs are on by default; the sink forwards whatever is enabled).
- `symbol_egress_cidrs` is accepted but unused: GCP IAM has no per-principal source-IP condition outside VPC Service Controls.
