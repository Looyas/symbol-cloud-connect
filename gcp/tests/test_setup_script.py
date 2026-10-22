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
LEGACY = "iam.disableServiceAccountKeyCreation"
MANAGED = "iam.managed.disableServiceAccountKeyCreation"

GCLOUD = r"""#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >> "$STUB_DIR/calls.log"
a="$*"
case "$a" in
  "auth list"*) echo "admin@acme.example" ;;
  "config get-value project"*) echo "acme-billing" ;;
  "projects describe"*) echo "acme-billing" ;;
  "services enable"*) exit 0 ;;
  "projects get-ancestors"*) echo "project acme-billing"; [ -n "${STUB_ORG:-}" ] && echo "organization $STUB_ORG"; exit 0 ;;
  "org-policies describe iam.disableServiceAccountKeyCreation "*) [ -n "${STUB_KEYS_LEGACY:-}" ] && printf '%s' "$STUB_KEYS_LEGACY" && exit 0; exit 1 ;;
  "org-policies describe iam.managed.disableServiceAccountKeyCreation "*) [ -n "${STUB_KEYS_MANAGED:-}" ] && printf '%s' "$STUB_KEYS_MANAGED" && exit 0; exit 1 ;;
  "resource-manager org-policies"*) exit 1 ;;
  "billing projects describe"*) [ -n "${STUB_BILLING:-}" ] && echo "billingAccounts/$STUB_BILLING"; exit 0 ;;
  "storage buckets list"*) [ "${STUB_BUCKET:-}" = "own" ] && echo "acme-billing-symbol-tfstate"; exit 0 ;;
  "storage buckets describe"*) [ -n "${STUB_BUCKET:-}" ] && exit 0; exit 1 ;;
  "storage buckets create"*|"storage buckets update"*) exit 0 ;;
  "storage cp"*)
    src=""; dst=""
    for x in "$@"; do case "$x" in storage|cp|--quiet) ;; *) if [ -z "$src" ]; then src="$x"; else dst="$x"; fi ;; esac; done
    case "$src" in gs://*) [ -n "${STUB_SAVED_VARS:-}" ] && cp "$STUB_SAVED_VARS" "$dst" && exit 0; exit 1 ;; *) cp "$src" "$STUB_DIR/saved.json" ;; esac ;;
  "storage cat"*) [ -n "${STUB_SAVED_VARS:-}" ] && cat "$STUB_SAVED_VARS" && exit 0; exit 1 ;;
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
      *symbol_connection_code*) echo "SYMBOL-GCP-2.eyJ2IjoyfQ" ;;
      *) echo "summary" ;;
    esac ;;
  *) exit 3 ;;
esac
"""

V2_ENFORCED = json.dumps({"spec": {"rules": [{"enforce": True}]}})
V2_NOT_ENFORCED = json.dumps({"spec": {"rules": [{"enforce": False}]}})
V1_ENFORCED = json.dumps({"constraint": "constraints/" + LEGACY, "booleanPolicy": {"enforced": True}})


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


def setup_args(*extra: str, modules: str = "finops,monitoring,security") -> list[str]:
    return ["--org", "2", "--session", SESSION, "--template", "gcp-v2.0.0", "--modules", modules,
            *extra]


def tfvars(stub) -> dict:
    return json.loads((stub.dir / "vars.json").read_text(encoding="utf-8"))


def calls(stub) -> str:
    return (stub.dir / "calls.log").read_text(encoding="utf-8")


ORG = {"STUB_ORG": "987654321"}
ALLOWED = {"STUB_KEYS_LEGACY": V2_NOT_ENFORCED, "STUB_KEYS_MANAGED": V2_NOT_ENFORCED}


# -- the identities: two service accounts with Google-generated keys --------------------


def test_no_organisation_reads_no_policy_and_prints_the_secret_code(stub) -> None:
    r = stub(setup_args())
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["allow_key_creation_exception"] is False and v["key_rotation_ids"] == {}
    assert v["organization_id"] == "" and v["scope_type"] == "project"
    assert v["create_dataset"] is True and v["billing_export_detected"] is False
    assert not {"identity_mode", "finops_principal", "finops_certificate_url"} & set(v)
    assert "SYMBOL-GCP-2.eyJ2IjoyfQ" in r.stdout
    assert "SECRET" in r.stdout and "nowhere else" in r.stdout
    log = calls(stub)
    assert ("storage buckets create gs://acme-billing-symbol-tfstate --project=acme-billing "
            "--location=US --uniform-bucket-level-access --public-access-prevention") in log
    assert "storage buckets update gs://acme-billing-symbol-tfstate --versioning" in log
    assert "-backend-config=prefix=symbol-cloud-connect/2" in log
    assert "orgpolicy.googleapis.com" not in log and "org-policies" not in log


def test_an_organisation_that_allows_keys(stub) -> None:
    r = stub(setup_args(), **ORG, **ALLOWED)
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["organization_id"] == "987654321" and v["allow_key_creation_exception"] is False
    log = calls(stub)
    assert "orgpolicy.googleapis.com" in log
    assert f"org-policies describe {LEGACY} --effective" in log
    assert f"org-policies describe {MANAGED} --effective" in log
    assert "Could not read" not in r.stderr


@pytest.mark.parametrize("env", [
    {"STUB_KEYS_MANAGED": V2_ENFORCED, "STUB_KEYS_LEGACY": V2_NOT_ENFORCED},
    {"STUB_KEYS_LEGACY": V2_ENFORCED},
    {"STUB_KEYS_LEGACY": V1_ENFORCED, "STUB_KEYS_MANAGED": V2_NOT_ENFORCED},
])
def test_forbidden_key_creation_stops_before_terraform_with_the_fix(stub, env) -> None:
    r = stub(setup_args(), **ORG, **env)
    assert r.returncode != 0
    assert "Service-account key creation is forbidden on acme-billing" in r.stderr
    assert "gcloud org-policies set-policy symbol-allow-keys.yaml" in r.stderr
    for constraint in (LEGACY, MANAGED):
        assert f"name: projects/acme-billing/policies/{constraint}" in r.stderr
    assert "--allow-key-creation-exception" in r.stderr
    log = calls(stub)
    assert "terraform init" not in log and "storage buckets create" not in log
    assert not (stub.dir / "vars.json").exists()


def test_the_printed_policy_command_writes_valid_yaml(stub) -> None:
    r = stub(setup_args(), **ORG, STUB_KEYS_MANAGED=V2_ENFORCED)
    line = next(l.strip() for l in r.stderr.splitlines()
                if l.strip().startswith(f"printf 'name: projects/acme-billing/policies/{MANAGED}"))
    out = subprocess.run([BASH, "-c", line.replace(" > symbol-allow-keys.yaml", "")],
                         capture_output=True, text=True, check=True).stdout
    assert out == (f"name: projects/acme-billing/policies/{MANAGED}\nspec:\n  rules:\n"
                   "  - enforce: false\n")


def test_the_exception_flag_lets_terraform_lift_the_policy(stub) -> None:
    r = stub(setup_args("--allow-key-creation-exception"), **ORG, STUB_KEYS_MANAGED=V2_ENFORCED)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["allow_key_creation_exception"] is True
    assert "the template creates an exception on acme-billing only" in r.stderr


def test_an_unreadable_policy_warns_and_continues(stub) -> None:
    r = stub(setup_args(), **ORG)
    assert r.returncode == 0, r.stderr
    assert "Could not read" in r.stderr and LEGACY in r.stderr and MANAGED in r.stderr
    assert tfvars(stub)["allow_key_creation_exception"] is False


# -- key rotation ---------------------------------------------------------------------


def _saved(stub, data: dict) -> str:
    saved = stub.dir / "saved-vars.json"
    saved.write_text(json.dumps(data), encoding="utf-8")
    return str(saved)


def test_a_rerun_keeps_the_previous_rotation_ids(stub) -> None:
    saved = _saved(stub, {"key_rotation_ids": {"finops": "abc-1", "observability": "def-2"}})
    r = stub(setup_args(), STUB_BUCKET="own", STUB_SAVED_VARS=saved)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["key_rotation_ids"] == {"finops": "abc-1", "observability": "def-2"}


def test_rotate_replaces_one_identity_only(stub) -> None:
    saved = _saved(stub, {"key_rotation_ids": {"observability": "def-2"}})
    r = stub(setup_args("--rotate", "finops"), STUB_BUCKET="own", STUB_SAVED_VARS=saved)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["key_rotation_ids"] == {"finops": SESSION, "observability": "def-2"}


def test_tampered_saved_rotation_ids_are_dropped(stub) -> None:
    saved = _saved(stub, {"key_rotation_ids": {"finops": 'a"b', "signin": "x", "observability": 3}})
    r = stub(setup_args(), STUB_BUCKET="own", STUB_SAVED_VARS=saved)
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["key_rotation_ids"] == {}


@pytest.mark.parametrize("rotate, modules, message", [
    ("signin", "finops", "--rotate must be finops or observability"),
    ("finops", "monitoring", "--rotate finops needs the finops module"),
    ("observability", "finops", "--rotate observability needs the monitoring or security module"),
])
def test_rotate_validation(stub, rotate, modules, message) -> None:
    r = stub(setup_args("--rotate", rotate, modules=modules))
    assert r.returncode != 0 and message in r.stderr
    assert not (stub.dir / "vars.json").exists()


# -- billing detection, scope, state ------------------------------------------------------


def test_export_detected_creates_view_not_dataset(stub) -> None:
    r = stub(setup_args(modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_v1_0123AB_CDEF45_6789AB,"
                         "gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB")
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["billing_account_id"] == "0123AB-CDEF45-6789AB" and v["billing_export_detected"] is True
    assert v["create_focus_view"] is True and v["create_dataset"] is False
    assert v["billing_dataset_location"] == "EU"
    assert v["enable_monitoring"] is False


def test_export_of_another_billing_account_is_used(stub) -> None:
    r = stub(setup_args(modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_ABCDEF_012345_6789AB")
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["billing_account_id"] == "ABCDEF-012345-6789AB"
    assert tfvars(stub)["billing_export_detected"] is True


def test_missing_export_prints_the_billing_console_link(stub) -> None:
    r = stub(setup_args(modules="finops"), STUB_BILLING="0123AB-CDEF45-6789AB")
    assert r.returncode == 0, r.stderr
    assert "https://console.cloud.google.com/billing/0123AB-CDEF45-6789AB/export" in r.stderr


def test_upgrade_keeps_managing_what_it_created(stub) -> None:
    r = stub(setup_args(modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB,gcp_focus_v1",
             STUB_STATE="module.finops[0].google_bigquery_dataset.billing[0],"
                        "module.finops[0].google_bigquery_table.focus[0]",
             STUB_BUCKET="own")
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["create_dataset"] is True and v["create_focus_view"] is True


def test_existing_view_not_owned_is_left_alone(stub) -> None:
    r = stub(setup_args(modules="finops"),
             STUB_BILLING="0123AB-CDEF45-6789AB", STUB_DATASET="1",
             STUB_TABLES="gcp_billing_export_resource_v1_0123AB_CDEF45_6789AB,gcp_focus_v1")
    assert r.returncode == 0, r.stderr
    assert tfvars(stub)["create_focus_view"] is False


def test_organization_scope_and_scc(stub) -> None:
    r = stub(setup_args("--scope", "organization:987654321", "--scc", modules="monitoring,security"),
             **ORG, **ALLOWED)
    assert r.returncode == 0, r.stderr
    v = tfvars(stub)
    assert v["scope_type"] == "organization" and v["scope_id"] == "987654321" and v["enable_scc"] is True
    assert v["enable_finops"] is False


def test_scope_of_another_organisation_is_refused(stub) -> None:
    r = stub(setup_args("--scope", "organization:111", modules="finops"), **ORG, **ALLOWED)
    assert r.returncode != 0 and "is not the organisation of acme-billing" in r.stderr


def test_squatted_state_bucket_is_refused(stub) -> None:
    r = stub(setup_args(modules="finops"), STUB_BUCKET="foreign")
    assert r.returncode != 0 and "does not belong to acme-billing" in r.stderr


# -- destroy --------------------------------------------------------------------------------


def test_destroy_uses_saved_variables_and_keeps_the_dataset(stub) -> None:
    saved = _saved(stub, {"symbol_org_id": "2", "allow_key_creation_exception": True})
    r = stub(["--destroy", "--org", "2", "--project", "acme-billing"], STUB_BUCKET="own",
             STUB_SAVED_VARS=saved, STUB_STATE="module.finops[0].google_bigquery_dataset.billing[0]")
    assert r.returncode == 0, r.stderr
    log = calls(stub)
    assert "terraform state rm module.finops[0].google_bigquery_dataset.billing[0]" in log
    assert "-destroy" in log and "-var=destroy_mode=true" in log
    assert log.index("terraform state rm") < log.index("terraform plan -destroy")
    assert "storage buckets create" not in log and "org-policies" not in log


def test_destroy_without_state_bucket_fails(stub) -> None:
    r = stub(["--destroy", "--org", "2", "--project", "acme-billing"])
    assert r.returncode != 0 and "nothing to destroy" in r.stderr


# -- arguments ------------------------------------------------------------------------------


@pytest.mark.parametrize("args, message", [
    (["--org", "a b"], "Invalid --org"),
    (setup_args()[:2] + ["--session", "x", "--template", "gcp-v2.0.0", "--modules", "finops"],
     "Invalid --session"),
    (setup_args("--scope", "folder:abc"), "Invalid --scope"),
    (setup_args(modules="finops,finops"), "listed twice"),
    (setup_args(modules="signin"), "Unknown module"),
    (setup_args("--billing-dataset", "a-b"), "Invalid --billing-dataset"),
    (setup_args("--org", "3; rm -rf /"), "Invalid --org"),
    # gcp-v1 flags are gone: a v1 command run against v2 stops at once.
    (setup_args("--identity-mode", "auto"), "Unknown argument '--identity-mode'"),
    (setup_args("--cert-base-url", "https://x.example/k"), "Unknown argument '--cert-base-url'"),
])
def test_argument_validation(stub, args: list[str], message: str) -> None:
    r = stub(args)
    assert r.returncode != 0 and message in r.stderr
    assert not (stub.dir / "vars.json").exists()
