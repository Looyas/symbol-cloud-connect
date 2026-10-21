"""Offline tests of symbol-setup.sh with stub gcloud / bq / terraform commands (pytest).

The stubs answer like Cloud Shell would for a scripted situation (organisation or not,
effective org policies, billing export present or not, earlier state) and record what
the script asks Terraform to do. Each test checks the decision the script took
(identity mode, Terraform variables, destroy behaviour), never a real cloud call.
Needs bash (Linux/macOS, or Git Bash on Windows).
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

GCP_DIR = Path(__file__).resolve().parents[1]
SCRIPT = GCP_DIR / "symbol-setup.sh"
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="bash not available")

SESSION = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
FIN = "sym-2-fin@symbol-prod.iam.gserviceaccount.com"
OBS = "sym-2-obs@symbol-prod.iam.gserviceaccount.com"
CERTS = "https://platform.example.com/api/cloud-connections/setup/public/sessions/" + SESSION + "/keys"

GCLOUD = r"""#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >> "$STUB_DIR/calls.log"
a="$*"
case "$a" in
  "auth list"*) echo "admin@acme.example" ;;
  "config get-value project"*) echo "acme-billing" ;;
  "projects describe"*) echo "acme-billing" ;;
  "services enable"*) exit 0 ;;
  "projects get-ancestors"*) echo "project acme-billing"; [ -n "${STUB_ORG:-}" ] && echo "organization $STUB_ORG"; exit 0 ;;
  "org-policies describe iam.allowedPolicyMemberDomains "*) [ -n "${STUB_DRS:-}" ] && printf '%s' "$STUB_DRS" && exit 0; exit 1 ;;
  "org-policies describe iam.managed.allowedPolicyMemberDomains "*) [ -n "${STUB_DRS_MANAGED:-}" ] && printf '%s' "$STUB_DRS_MANAGED" && exit 0; exit 1 ;;
  "org-policies describe iam.disableServiceAccountKeyUpload "*) [ -n "${STUB_UPLOAD:-}" ] && printf '%s' "$STUB_UPLOAD" && exit 0; exit 1 ;;
  "org-policies describe iam.managed.disableServiceAccountKeyUpload "*) [ -n "${STUB_UPLOAD_MANAGED:-}" ] && printf '%s' "$STUB_UPLOAD_MANAGED" && exit 0; exit 1 ;;
  "resource-manager org-policies"*) exit 1 ;;
  "billing projects describe"*) [ -n "${STUB_BILLING:-}" ] && echo "billingAccounts/$STUB_BILLING"; exit 0 ;;
  "storage buckets list"*) [ "${STUB_BUCKET:-}" = "own" ] && echo "acme-billing-symbol-tfstate"; exit 0 ;;
  "storage buckets describe"*) [ -n "${STUB_BUCKET:-}" ] && exit 0; exit 1 ;;
  "storage buckets create"*|"storage buckets update"*) exit 0 ;;
  "storage cp"*)
    src=""; dst=""
    for x in "$@"; do case "$x" in storage|cp|--quiet) ;; *) if [ -z "$src" ]; then src="$x"; else dst="$x"; fi ;; esac; done
    case "$src" in gs://*) [ -n "${STUB_SAVED_VARS:-}" ] && cp "$STUB_SAVED_VARS" "$dst" && exit 0; exit 1 ;; *) cp "$src" "$STUB_DIR/saved.json" ;; esac ;;
  "storage rm"*) exit 0 ;;
  *) echo "unexpected gcloud $a" >&2; exit 3 ;;
esac
"""

BQ = r"""#!/usr/bin/env bash
printf 'bq %s\n' "$*" >> "$STUB_DIR/calls.log"
cmd=""; for x in "$@"; do case "$x" in show|ls) cmd="$x" ;; esac; done
target="${@: -1}"
case "$cmd" in
  show) [ "${STUB_DATASET:-}" = "1" ] && [ "$target" = "acme-billing:billing_export" ] && echo '{"location": "EU"}' && exit 0; exit 1 ;;
  ls) [ "${STUB_DATASET:-}" = "1" ] || exit 1
      printf '['; sep=""; IFS=','; for t in ${STUB_TABLES:-}; do printf '%s{"tableReference": {"tableId": "%s"}}' "$sep" "$t"; sep=","; done; printf ']\n' ;;
  *) exit 3 ;;
esac
"""

TERRAFORM = r"""#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >> "$STUB_DIR/calls.log"
case "$1" in
  version) echo '{"terraform_version": "1.9.8", "platform": "linux_amd64"}' ;;
  init|apply) exit 0 ;;
  state)
    if [ "$2" = "list" ]; then printf '%s' "${STUB_STATE:-}" | tr ',' '\n'; fi
    exit 0 ;;
  plan) for x in "$@"; do case "$x" in -var-file=*) cp "${x#-var-file=}" "$STUB_DIR/vars.json" ;; esac; done; exit 0 ;;
  output)
    case "$*" in
      *symbol_connection_code*) echo "SYMBOL-GCP-1.eyJ2IjoxfQ" ;;
      *) echo "summary" ;;
    esac ;;
  *) exit 3 ;;
esac
"""

V2_ALLOW_ALL = json.dumps({"spec": {"rules": [{"allowAll": True}]}})
V2_RESTRICTED = json.dumps({"spec": {"rules": [{"values": {"allowedValues": ["C0abc123"]}}]}})
V2_ENFORCED = json.dumps({"spec": {"rules": [{"enforce": True}]}})
V2_NOT_ENFORCED = json.dumps({"spec": {"rules": [{"enforce": False}]}})


@pytest.fixture()
def stub(tmp_path: Path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    # python3 = this interpreter (Cloud Shell has python3; on Windows "python3" may be
    # the Microsoft Store alias).
    python3 = '#!/usr/bin/env bash\nexec "%s" "$@"\n' % sys.executable.replace("\\", "/")
    for name, body in (("gcloud", GCLOUD), ("bq", BQ), ("terraform", TERRAFORM), ("python3", python3)):
        p = bindir / name
        p.write_text(body, encoding="utf-8", newline="\n")
        p.chmod(p.stat().st_mode | stat.S_IEXEC)

    def run(args: list[str], **env: str) -> subprocess.CompletedProcess:
        e = dict(os.environ)
        e.update({"STUB_DIR": str(tmp_path), "HOME": str(tmp_path), "TMPDIR": str(tmp_path)})
        e["PATH"] = str(bindir) + os.pathsep + e.get("PATH", "")
        e.update(env)
        return subprocess.run([BASH, str(SCRIPT), *args, "--yes"], env=e, capture_output=True,
                              text=True, timeout=120, check=False)

    run.dir = tmp_path  # type: ignore[attr-defined]
    return run


def setup_args(*extra: str, modules: str = "finops,monitoring,security", mode: str = "auto") -> list[str]:
    return ["--org", "2", "--session", SESSION, "--template", "gcp-v1.0.0", "--modules", modules,
            "--identity-mode", mode, *extra]


def tfvars(stub) -> dict:
    return json.loads((stub.dir / "vars.json").read_text(encoding="utf-8"))


def calls(stub) -> str:
    return (stub.dir / "calls.log").read_text(encoding="utf-8")


def test_no_organisation_uses_symbol_principal(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS, "--cert-base-url", CERTS))
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["identity_mode"] == "symbol_principal"
    assert v["finops_principal"] == FIN and v["observability_principal"] == OBS
    assert v["finops_certificate_url"] == "" and v["organization_id"] == ""
    assert v["scope_type"] == "project" and v["create_dataset"] is True and v["billing_export_detected"] is False
    assert "SYMBOL-GCP-1.eyJ2IjoxfQ" in r.stdout
    assert "storage buckets create gs://acme-billing-symbol-tfstate --project=acme-billing --location=US --uniform-bucket-level-access --public-access-prevention" in calls(stub)
    assert "storage buckets update gs://acme-billing-symbol-tfstate --versioning" in calls(stub)
    assert "-backend-config=prefix=symbol-cloud-connect/2" in calls(stub)
    assert "orgpolicy.googleapis.com" not in calls(stub)


def test_domain_restricted_sharing_falls_back_to_key_upload(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS, "--cert-base-url", CERTS),
             STUB_ORG="987654321", STUB_DRS=V2_RESTRICTED, STUB_UPLOAD=V2_NOT_ENFORCED, STUB_BUCKET="own")
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["identity_mode"] == "key_upload"
    assert v["finops_principal"] == "" and v["observability_principal"] == ""
    assert v["finops_certificate_url"] == CERTS + "/finops.crt"
    assert v["observability_certificate_url"] == CERTS + "/observability.crt"
    assert "Domain restricted sharing is enforced" in r.stderr
    assert "orgpolicy.googleapis.com" in calls(stub)


def test_allow_all_keeps_symbol_principal_in_an_organisation(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS, "--cert-base-url", CERTS),
             STUB_ORG="987654321", STUB_DRS=V2_ALLOW_ALL, STUB_UPLOAD=V2_ENFORCED)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["identity_mode"] == "symbol_principal"
    assert tfvars(stub)["organization_id"] == "987654321"


def test_managed_drs_constraint_counts_as_restricted(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS, "--cert-base-url", CERTS),
             STUB_ORG="987654321", STUB_DRS=V2_ALLOW_ALL, STUB_DRS_MANAGED=V2_ENFORCED)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["identity_mode"] == "key_upload"


def test_both_blocked_stops_naming_both_constraints(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS, "--cert-base-url", CERTS),
             STUB_ORG="987654321", STUB_DRS=V2_RESTRICTED, STUB_UPLOAD_MANAGED=V2_ENFORCED)
    assert r.returncode != 0
    assert "iam.allowedPolicyMemberDomains" in r.stderr and "iam.disableServiceAccountKeyUpload" in r.stderr
    assert not (stub.dir / "vars.json").exists()


def test_explicit_key_upload_refused_when_upload_disabled(stub) -> None:
    r = stub(setup_args("--cert-base-url", CERTS, mode="key_upload"), STUB_ORG="987654321", STUB_UPLOAD=V2_ENFORCED)
    assert r.returncode != 0 and "key upload is disabled" in r.stderr


def test_missing_principals_without_certificates_fails(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN))
    assert r.returncode != 0 and "No identity mode is possible" in r.stderr


def test_export_detected_creates_view_not_dataset(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_v1_0123AB_CDEF45_6789AB,gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB")
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["billing_account_id"] == "0123AB-CDEF45-6789AB" and v["billing_export_detected"] is True
    assert v["create_focus_view"] is True and v["create_dataset"] is False
    assert v["billing_dataset_location"] == "EU"
    assert v["enable_monitoring"] is False and v["observability_principal"] == ""


def test_export_of_another_billing_account_is_used(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_ABCDEF_012345_6789AB")
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["billing_account_id"] == "ABCDEF-012345-6789AB"
    assert tfvars(stub)["billing_export_detected"] is True


def test_missing_export_prints_the_billing_console_link(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"), STUB_BILLING="0123AB-CDEF45-6789AB")
    assert r.returncode == 0, r.stderr
    assert "https://console.cloud.google.com/billing/0123AB-CDEF45-6789AB/export" in r.stderr


def test_upgrade_keeps_managing_what_it_created(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB,gcp_focus_v1",
             STUB_STATE="module.finops[0].google_bigquery_dataset.billing[0],module.finops[0].google_bigquery_table.focus[0]",
             STUB_BUCKET="own")
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["create_dataset"] is True and v["create_focus_view"] is True


def test_existing_view_not_owned_is_left_alone(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB,gcp_focus_v1")
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["create_focus_view"] is False


def test_organization_scope_and_scc(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--observability-principal", OBS,
                        "--scope", "organization:987654321", "--scc", modules="monitoring,security"),
             STUB_ORG="987654321", STUB_DRS=V2_ALLOW_ALL)
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["scope_type"] == "organization" and v["scope_id"] == "987654321" and v["enable_scc"] is True
    assert v["finops_principal"] == "" or v["enable_finops"] is False


def test_scope_of_another_organisation_is_refused(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, "--scope", "organization:111", modules="finops"),
             STUB_ORG="987654321", STUB_DRS=V2_ALLOW_ALL)
    assert r.returncode != 0 and "is not the organisation of acme-billing" in r.stderr


def test_squatted_state_bucket_is_refused(stub) -> None:
    r = stub(setup_args("--finops-principal", FIN, modules="finops"), STUB_BUCKET="foreign")
    assert r.returncode != 0 and "does not belong to acme-billing" in r.stderr


def test_destroy_uses_saved_variables_and_keeps_the_dataset(stub) -> None:
    saved = stub.dir / "saved-vars.json"
    saved.write_text(json.dumps({"symbol_org_id": "2", "identity_mode": "key_upload"}), encoding="utf-8")
    r = stub(["--destroy", "--org", "2", "--project", "acme-billing"], STUB_BUCKET="own",
             STUB_SAVED_VARS=str(saved), STUB_STATE="module.finops[0].google_bigquery_dataset.billing[0]")
    assert r.returncode == 0, r.stderr
    log = calls(stub)
    assert "terraform state rm module.finops[0].google_bigquery_dataset.billing[0]" in log
    assert "-destroy" in log and "-var=destroy_mode=true" in log
    assert log.index("terraform state rm") < log.index("terraform plan -destroy")
    assert "storage buckets create" not in log


def test_destroy_without_state_bucket_fails(stub) -> None:
    r = stub(["--destroy", "--org", "2", "--project", "acme-billing"])
    assert r.returncode != 0 and "nothing to destroy" in r.stderr


@pytest.mark.parametrize("args, message", [
    (["--org", "a b"], "Invalid --org"),
    (setup_args()[:2] + ["--session", "x", "--template", "gcp-v1.0.0", "--modules", "finops"], "Invalid --session"),
    (setup_args("--cert-base-url", "http://insecure.example.com/k"), "must be an https URL"),
    (setup_args("--scope", "folder:abc"), "Invalid --scope"),
    (setup_args(modules="finops,finops"), "listed twice"),
    (setup_args(modules="signin"), "Unknown module"),
    (setup_args("--finops-principal", "x@gmail.com"), "Invalid --finops-principal"),
    (setup_args("--billing-dataset", "a-b"), "Invalid --billing-dataset"),
    (setup_args("--org", "3; rm -rf /"), "Invalid --org"),
])
def test_argument_validation(stub, args: list[str], message: str) -> None:
    r = stub(args)
    assert r.returncode != 0 and message in r.stderr
    assert not (stub.dir / "vars.json").exists()
