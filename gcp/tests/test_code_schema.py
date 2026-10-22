"""Cross-checks of the GCP template outside Terraform (pytest).

1. The connection codes produced by the Terraform test runs (mocked providers, FAKE key
   files) satisfy CLOUD-SETUP-CONTRACT-V2 §5.7 (code version 2) exactly, decoded the way
   Symbol decodes them; and, when connections-service is checked out next to this
   repository, its own decoder (app.setup.connection_code.decode) accepts them.
2. The FOCUS view produces exactly the columns Symbol's GCP reader consumes
   (finops-module/ingestion-service/transformers/gcp_transformer.py).
3. No authoritative IAM resource (*_iam_policy / *_iam_binding) is ever used.

Codes come from `terraform test -verbose` when Terraform is available (TERRAFORM env
var or `terraform` on PATH, with `terraform init -backend=false` already run), else from
tests/fixtures/connection_codes.json. The code output is sensitive, so each code-producing
run is followed by a reveal_<run> run of tests/reveal, which prints it. Regenerate the
fixture with:

    python tests/test_code_schema.py --update-fixtures
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

GCP_DIR = Path(__file__).resolve().parents[1]
FIXTURE = GCP_DIR / "tests" / "fixtures" / "connection_codes.json"
PREFIX = "SYMBOL-GCP-2."
CODE_VERSION = 2
MAX_LENGTH = 16384

TOP_KEYS = {
    "v", "org", "session", "template", "project", "project_number", "organization_id",
    "scope", "modules", "key", "finops", "observability",
}
KEY_KEYS = {"service_account", "key_id", "valid_after", "valid_before", "credentials"}
#: The fields of a Google service-account key file (TYPE_GOOGLE_CREDENTIALS_FILE).
CREDENTIAL_KEYS = {
    "type", "project_id", "private_key_id", "private_key", "client_email", "client_id",
    "auth_uri", "token_uri", "auth_provider_x509_cert_url", "client_x509_cert_url",
    "universe_domain",
}
TOKEN_URI = "https://oauth2.googleapis.com/token"
FINOPS_KEYS = {
    "project_id", "dataset", "table", "billing_account_id", "billing_export_detected",
    "focus_view_created",
}
OBSERVABILITY_KEYS = {
    "project_id", "subscription_id", "scc_subscription_id", "audit_scope_type", "audit_scope_id",
}
MODULE_ORDER = ["finops", "monitoring", "security"]

RE_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RE_PROJECT = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
RE_SA = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$")
RE_KEY_ID = re.compile(r"^[0-9a-f]{40}$")
RE_TIMESTAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$")
RE_BILLING = re.compile(r"^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$")
RE_DATASET = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,1023}$")
RE_SUBSCRIPTION = re.compile(r"^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/subscriptions/[A-Za-z][A-Za-z0-9._~%+-]{2,254}$")


# ---------------------------------------------------------------------------
# Code sources
# ---------------------------------------------------------------------------

def _terraform() -> str | None:
    candidate = os.environ.get("TERRAFORM") or shutil.which("terraform")
    if candidate and (Path(candidate).exists() or shutil.which(candidate)):
        return candidate
    return None


def codes_from_terraform(terraform: str) -> dict[str, str]:
    """Run the mocked Terraform tests and collect every revealed code by its source run."""
    proc = subprocess.run(
        [terraform, "test", "-verbose", "-no-color"],
        cwd=GCP_DIR, capture_output=True, text=True, timeout=1800, check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError("terraform test failed:\n" + proc.stdout[-4000:] + proc.stderr[-4000:])
    codes: dict[str, str] = {}
    run = None
    for line in proc.stdout.splitlines():
        m = re.match(r'^\s*run "([^"]+)"\.\.\.', line)
        if m:
            run = m.group(1)
            continue
        m = re.match(r'^revealed_code = "(SYMBOL-GCP-2\.[A-Za-z0-9_-]+)"$', line.strip())
        if m and run and run.startswith("reveal_"):
            codes[run[len("reveal_"):]] = m.group(1)
    if not codes:
        raise RuntimeError("no revealed_code found in `terraform test -verbose` output")
    return codes


def load_codes() -> dict[str, str]:
    terraform = _terraform()
    if terraform and os.environ.get("SYMBOL_SKIP_TERRAFORM") != "1":
        try:
            return codes_from_terraform(terraform)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:  # pragma: no cover - env specific
            if os.environ.get("CI"):
                raise
            print(f"terraform unavailable ({exc}); using the fixture", file=sys.stderr)
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


CODES = load_codes()


# ---------------------------------------------------------------------------
# Decoding (same algorithm as connections-service app/setup/connection_code.decode)
# ---------------------------------------------------------------------------

def decode(code: str) -> dict:
    text = "".join(code.split())
    assert len(text) <= MAX_LENGTH
    assert text.startswith(PREFIX)
    body = text[len(PREFIX):]
    normalised = body.replace("-", "+").replace("_", "/")
    data = json.loads(base64.b64decode(normalised + "=" * (-len(normalised) % 4), validate=True))
    assert isinstance(data, dict)
    assert data.get("v") == CODE_VERSION
    return data


def _backend_decoder():
    """connections-service's decoder when the DAAS checkout is reachable, else None."""
    candidates = [os.environ.get("SYMBOL_CONNECTIONS_SERVICE", "")]
    candidates.append(str(GCP_DIR.parents[1] / "DAAS" / "backend" / "connections-service"))
    for root in filter(None, candidates):
        if (Path(root) / "app" / "setup" / "connection_code.py").exists():
            sys.path.insert(0, root)
            try:
                from app.setup import connection_code  # type: ignore
            except Exception:  # pragma: no cover - backend deps missing
                return None
            finally:
                sys.path.pop(0)
            return connection_code.decode
    return None


# ---------------------------------------------------------------------------
# §5.7 schema
# ---------------------------------------------------------------------------

def assert_schema(data: dict) -> None:
    assert set(data) == TOP_KEYS, set(data) ^ TOP_KEYS
    assert data["v"] == CODE_VERSION and isinstance(data["v"], int)
    assert re.fullmatch(r"[A-Za-z0-9_-]{1,64}", data["org"])
    assert RE_UUID.fullmatch(data["session"])
    assert re.fullmatch(r"gcp-v\d+\.\d+\.\d+", data["template"])
    assert RE_PROJECT.fullmatch(data["project"])
    assert isinstance(data["project_number"], str) and data["project_number"].isdigit()
    assert isinstance(data["organization_id"], str) and (data["organization_id"] == "" or data["organization_id"].isdigit())

    scope = data["scope"]
    assert set(scope) == {"type", "id"}
    assert scope["type"] in {"project", "folder", "organization"}
    if scope["type"] == "project":
        assert scope["id"] == data["project"]
    else:
        assert scope["id"].isdigit()
    if scope["type"] == "organization":
        assert scope["id"] == data["organization_id"]

    modules = data["modules"]
    assert modules and modules == [m for m in MODULE_ORDER if m in modules], "modules must follow §1 order, no duplicates"
    needs_fin = "finops" in modules
    needs_obs = "monitoring" in modules or "security" in modules

    key = data["key"]
    assert set(key) == {"finops", "observability"}
    for identity, needed in (("finops", needs_fin), ("observability", needs_obs)):
        if not needed:
            assert key[identity] is None
            continue
        entry = key[identity]
        assert set(entry) == KEY_KEYS, set(entry) ^ KEY_KEYS
        email = f"symbol-{identity}@{data['project']}.iam.gserviceaccount.com"
        assert entry["service_account"] == email
        assert RE_KEY_ID.fullmatch(entry["key_id"])
        assert RE_TIMESTAMP.fullmatch(entry["valid_after"]) and RE_TIMESTAMP.fullmatch(entry["valid_before"])
        credentials = entry["credentials"]
        assert set(credentials) == CREDENTIAL_KEYS, set(credentials) ^ CREDENTIAL_KEYS
        assert credentials["type"] == "service_account"
        assert credentials["project_id"] == data["project"]
        assert credentials["private_key_id"] == entry["key_id"]
        assert credentials["client_email"] == email
        assert credentials["token_uri"] == TOKEN_URI
        assert isinstance(credentials["private_key"], str) and credentials["private_key"]
    if needs_fin and needs_obs:
        assert key["finops"]["key_id"] != key["observability"]["key_id"]

    finops = data["finops"]
    if not needs_fin:
        assert finops is None
    else:
        assert set(finops) == FINOPS_KEYS
        assert finops["project_id"] == data["project"]
        assert RE_DATASET.fullmatch(finops["dataset"])
        assert finops["table"] == "gcp_focus_v1"
        assert finops["billing_account_id"] is None or RE_BILLING.fullmatch(finops["billing_account_id"])
        assert isinstance(finops["billing_export_detected"], bool)
        assert isinstance(finops["focus_view_created"], bool)
        if finops["focus_view_created"]:
            assert finops["billing_export_detected"] and finops["billing_account_id"]

    obs = data["observability"]
    if not needs_obs:
        assert obs is None
    else:
        assert set(obs) == OBSERVABILITY_KEYS
        assert obs["project_id"] == data["project"]
        if "monitoring" in modules:
            assert RE_SUBSCRIPTION.fullmatch(obs["subscription_id"])
            assert obs["subscription_id"] == f"projects/{data['project']}/subscriptions/symbol-monitoring-sub"
        else:
            assert obs["subscription_id"] is None and obs["scc_subscription_id"] is None
        assert obs["scc_subscription_id"] is None or obs["scc_subscription_id"] == f"projects/{data['project']}/subscriptions/symbol-scc-sub"
        assert obs["audit_scope_type"] == scope["type"] and obs["audit_scope_id"] == scope["id"]


@pytest.mark.parametrize("run", sorted(CODES))
def test_code_matches_contract(run: str) -> None:
    code = CODES[run]
    assert "=" not in code and not re.search(r"[+/]", code[len(PREFIX):]), "unpadded base64url"
    assert_schema(decode(code))


@pytest.mark.parametrize("run", sorted(CODES))
def test_backend_decoder_accepts_code(run: str) -> None:
    backend_decode = _backend_decoder()
    if backend_decode is None:
        pytest.skip("connections-service checkout not found (set SYMBOL_CONNECTIONS_SERVICE)")
    assert backend_decode(CODES[run], prefix=PREFIX, version=CODE_VERSION,
                          max_length=MAX_LENGTH) == decode(CODES[run])


def test_every_module_set_and_scope_is_covered() -> None:
    decoded = [decode(c) for c in CODES.values()]
    assert {d["scope"]["type"] for d in decoded} == {"project", "folder", "organization"}
    assert {tuple(d["modules"]) for d in decoded} >= {
        ("finops", "monitoring", "security"), ("finops",), ("monitoring",), ("security",)}
    assert any(d["observability"] and d["observability"]["scc_subscription_id"] for d in decoded)


# ---------------------------------------------------------------------------
# FOCUS view columns vs. Symbol's reader
# ---------------------------------------------------------------------------

# Frozen copy of the raw.get("<column>") keys of gcp_transformer.py (Symbol DAAS,
# finops-module/ingestion-service/transformers/gcp_transformer.py, Oct 2026). The test
# below re-reads the live file when the DAAS checkout is reachable.
READER_COLUMNS = {
    "BillingAccountId", "BillingAccountName", "SubAccountId", "SubAccountName",
    "BilledCost", "BillingCurrency", "UsageQuantity", "UsageUnit", "EffectiveCost",
    "ListCost", "ListUnitPrice", "ChargeCategory", "ChargeDescription", "ChargeFrequency",
    "BillingPeriodStart", "BillingPeriodEnd", "ChargePeriodStart", "ChargePeriodEnd",
    "InvoiceIssuer", "Provider", "Publisher", "PricingCategory", "PricingQuantity",
    "PricingUnit", "CommitmentDiscountCategory", "CommitmentDiscountId",
    "CommitmentDiscountName", "CommitmentDiscountType", "ServiceCategory", "ServiceName",
    "SkuId", "SkuPriceId", "ResourceId", "ResourceName", "ResourceType",
    "AvailabilityZone", "Region", "Tags",
}


def view_columns() -> list[str]:
    sql = (GCP_DIR / "modules" / "finops" / "focus_view.sql.tftpl").read_text(encoding="utf-8")
    final_select = sql[sql.rindex("\nSELECT"):]
    # Top-level select items are indented by exactly two spaces (nested STRUCT fields
    # inside Tags are indented further).
    return re.findall(r"^  \S.*\bAS ([A-Za-z_][A-Za-z0-9_]*),?\s*$", final_select, flags=re.M)


def test_view_columns_are_exactly_what_the_reader_reads() -> None:
    cols = view_columns()
    assert len(cols) == len(set(cols)), "duplicate column"
    focus = {c for c in cols if not c.startswith("gcp_")}
    assert focus == READER_COLUMNS, {"missing": READER_COLUMNS - focus, "unread": focus - READER_COLUMNS}
    # Extension columns are packed into x_provider_details by the reader (gcp_ prefix).
    assert all(re.fullmatch(r"gcp_[A-Za-z]+", c) for c in cols if c.startswith("gcp_"))


def test_reader_columns_match_live_transformer() -> None:
    path = Path(os.environ.get("SYMBOL_DAAS_DIR", GCP_DIR.parents[1] / "DAAS")) / "backend" / "finops-module" / "ingestion-service" / "transformers" / "gcp_transformer.py"
    if not path.exists():
        pytest.skip("DAAS checkout not found (set SYMBOL_DAAS_DIR)")
    live = set(re.findall(r'raw\.get\("([A-Za-z_]+)"\)', path.read_text(encoding="utf-8")))
    assert live == READER_COLUMNS, {"new in reader": live - READER_COLUMNS, "gone": READER_COLUMNS - live}


def test_view_sql_is_parameterised_only_by_validated_identifiers() -> None:
    sql = (GCP_DIR / "modules" / "finops" / "focus_view.sql.tftpl").read_text(encoding="utf-8")
    assert set(re.findall(r"\$\{([a-z_]+)\}", sql)) == {"project", "dataset", "source_table", "billing_account_id"}
    assert "%{" not in sql


# ---------------------------------------------------------------------------
# IAM: additive grants only
# ---------------------------------------------------------------------------

def test_no_authoritative_iam_resources() -> None:
    offenders = []
    for tf in GCP_DIR.rglob("*.tf"):
        if ".terraform" in tf.parts:
            continue
        for n, line in enumerate(tf.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r'^\s*(resource|data)\s+"google_\w+_iam_(policy|binding)"', line):
                offenders.append(f"{tf.relative_to(GCP_DIR)}:{n}: {line.strip()}")
    assert not offenders, "use google_*_iam_member only:\n" + "\n".join(offenders)


def test_iam_member_resources_exist() -> None:
    text = "\n".join(p.read_text(encoding="utf-8") for p in GCP_DIR.rglob("*.tf") if ".terraform" not in p.parts)
    assert re.search(r'resource "google_project_iam_member"', text)
    assert re.search(r'resource "google_folder_iam_member"', text)
    assert re.search(r'resource "google_organization_iam_member"', text)


if __name__ == "__main__":
    if "--update-fixtures" in sys.argv:
        terraform = _terraform()
        if not terraform:
            raise SystemExit("terraform not found (set TERRAFORM)")
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_text(json.dumps(codes_from_terraform(terraform), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"wrote {FIXTURE}")
    else:
        raise SystemExit(pytest.main([__file__, "-q"]))
