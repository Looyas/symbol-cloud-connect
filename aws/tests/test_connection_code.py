"""Renders SymbolConnectionCode for every module combination and checks it against the
contract (CLOUD-SETUP-CONTRACT-V2 §4.5): exact keys, key order, types and nulls."""
import fnmatch
import itertools
import json
import re

import pytest

import cfn
from conftest import SYMBOL_PARAMS

MODULE_ORDER = ("signin", "finops", "monitoring", "security")
FLAG = {"signin": "EnableSignin", "finops": "EnableFinops",
        "monitoring": "EnableMonitoring", "security": "EnableSecurity"}

TOP_KEYS = ["v", "org", "session", "template", "account", "partition", "region", "modules",
            "signin", "finops", "observability", "monitoring", "security"]
SIGNIN_KEYS = ["identity_center_region", "start_url", "discovered", "problem"]
FINOPS_KEYS = ["role_arn", "payer_account_id", "bucket", "bucket_region", "prefix",
               "export_name", "export_created"]
OBSERVABILITY_KEYS = ["role_arn", "account_id", "region"]
MONITORING_KEYS = ["queue_url", "rule_name"]
SECURITY_KEYS = ["managed_policies"]

START_URL = re.compile(r"^https://[A-Za-z0-9-]+\.awsapps\.com/start/?$")

DISCOVERED = {"Region": "eu-west-1", "StartUrl": "https://d-1234567890.awsapps.com/start",
              "InstanceArn": "arn:aws:sso:::instance/ssoins-1234567890abcdef", "Problem": ""}
NOT_FOUND = {"Region": "", "StartUrl": "", "InstanceArn": "",
             "Problem": "No IAM Identity Center instance found in this account (17 Regions "
                        "checked, 3 not enabled). Enter IdentityCenterRegion and "
                        "IdentityCenterStartUrl, then update the stack."}

FINOPS_VARIANTS = {
    "created": {"CreateFocusExport": "true"},
    "existing": {"CreateFocusExport": "false", "ExistingExportBucket": "acme-cur",
                 "ExistingExportPrefix": "billing/focus", "ExistingExportName": "acme-focus"},
    "existing-no-prefix": {"CreateFocusExport": "false", "ExistingExportBucket": "acme-cur",
                           "ExistingExportName": "acme-focus"},
}
SIGNIN_VARIANTS = {
    "discovered": ({}, DISCOVERED),
    "not-found": ({}, NOT_FOUND),
    "given": ({"IdentityCenterRegion": "eu-central-1",
               "IdentityCenterStartUrl": "https://acme.awsapps.com/start"}, None),
}


def module_sets():
    for flags in itertools.product([True, False], repeat=4):
        if any(flags):
            yield tuple(m for m, on in zip(MODULE_ORDER, flags) if on)


def scenarios():
    for modules in module_sets():
        for fin in FINOPS_VARIANTS if "finops" in modules else ["created"]:
            for sig in SIGNIN_VARIANTS if "signin" in modules else ["discovered"]:
                for cidrs in ("with-cidrs", "no-cidrs"):
                    yield pytest.param(modules, fin, sig, cidrs,
                                       id=f"{'+'.join(modules)}-{fin}-{sig}-{cidrs}")


def build(stack, modules, finops_variant="created", signin_variant="discovered",
          cidrs="with-cidrs", **overrides):
    params = dict(SYMBOL_PARAMS)
    if cidrs == "no-cidrs":
        params["SymbolEgressCidrs"] = ""
    for module in MODULE_ORDER:
        params[FLAG[module]] = "true" if module in modules else "false"
    params.update(FINOPS_VARIANTS[finops_variant])
    signin_params, discovery = SIGNIN_VARIANTS[signin_variant]
    params.update(signin_params)
    params.update(overrides)
    attributes = {"IdentityCenterDiscovery": discovery} if discovery else {}
    return cfn.Evaluator(stack, params, attributes=attributes)


def render_outputs(ev, stack):
    """Every output whose Condition holds, plus every enabled resource's properties:
    CloudFormation would reject a reference to a disabled resource in either."""
    for logical_id, resource in stack["Resources"].items():
        if ev.resource_enabled(logical_id):
            ev.resolve(resource.get("Properties", {}))
    outputs = {}
    for name, output in stack["Outputs"].items():
        if "Condition" in output and not ev.condition(output["Condition"]):
            continue
        outputs[name] = ev.resolve(output["Value"])
    return outputs


def reader_export_path(prefix, export_name):
    """Exactly how the FinOps reader (aws_extractor._export_path) and the connections-service
    preflight (export_path) build the S3 listing prefix."""
    cleaned = (prefix or "").lstrip("/")
    if cleaned and not cleaned.endswith("/"):
        cleaned += "/"
    name = (export_name or "").strip("/")
    return f"{cleaned}{name}/" if name else cleaned


@pytest.mark.parametrize("modules,finops_variant,signin_variant,cidrs", list(scenarios()))
def test_connection_code_matches_contract(stack, modules, finops_variant, signin_variant, cidrs):
    ev = build(stack, modules, finops_variant, signin_variant, cidrs)
    assert ev.failed_rules() == []
    outputs = render_outputs(ev, stack)
    code = outputs["SymbolConnectionCode"]

    assert code.startswith("SYMBOL-AWS-1.")
    assert len(code) <= 4096, "keep well under the decoder's 8192-character limit"
    data = cfn.decode_connection_code(code)

    assert list(data) == TOP_KEYS
    assert data["v"] == 1 and type(data["v"]) is int
    for key in ("org", "session", "template", "account", "partition", "region"):
        assert isinstance(data[key], str)
    assert data["org"] == SYMBOL_PARAMS["SymbolOrgId"]
    assert data["session"] == SYMBOL_PARAMS["SetupSessionId"]
    assert data["template"] == "aws-v1.0.0"
    assert re.fullmatch(r"\d{12}", data["account"])
    assert data["partition"] in ("aws", "aws-cn", "aws-us-gov")
    assert data["region"] == "us-east-1"
    assert data["modules"] == list(modules)

    org, account = data["org"], data["account"]

    # signin
    if "signin" in modules:
        signin = data["signin"]
        assert list(signin) == SIGNIN_KEYS
        assert isinstance(signin["discovered"], bool)
        assert all(isinstance(signin[k], str) for k in SIGNIN_KEYS if k != "discovered")
        if signin_variant == "given":
            assert signin == {"identity_center_region": "eu-central-1",
                              "start_url": "https://acme.awsapps.com/start",
                              "discovered": False, "problem": ""}
        elif signin_variant == "discovered":
            assert signin == {"identity_center_region": "eu-west-1",
                              "start_url": "https://d-1234567890.awsapps.com/start",
                              "discovered": True, "problem": ""}
        else:
            assert signin["discovered"] is True and signin["start_url"] == ""
            assert signin["identity_center_region"] == "" and signin["problem"]
        if signin["start_url"]:
            assert START_URL.match(signin["start_url"])
    else:
        assert data["signin"] is None

    # finops
    if "finops" in modules:
        finops = data["finops"]
        assert list(finops) == FINOPS_KEYS
        assert isinstance(finops["export_created"], bool)
        assert all(isinstance(finops[k], str) for k in FINOPS_KEYS if k != "export_created")
        assert finops["role_arn"] == f"arn:aws:iam::{account}:role/SymbolFinOps-{org}"
        assert finops["payer_account_id"] == account
        assert finops["bucket_region"] == "us-east-1"
        assert not finops["prefix"].endswith("/") and not finops["prefix"].startswith("/")
        if finops_variant == "created":
            assert finops["export_created"] is True
            assert finops["bucket"] == f"symbol-focus-{account}-1a2b3c4d"
            assert finops["prefix"] == "symbol-focus"
            assert finops["export_name"] == f"symbol-focus-{org}"
        else:
            assert finops["export_created"] is False
            assert finops["bucket"] == "acme-cur"
            assert finops["export_name"] == "acme-focus"
            assert finops["prefix"] == ("billing/focus" if finops_variant == "existing" else "")
    else:
        assert data["finops"] is None

    # observability / monitoring / security
    if {"monitoring", "security"} & set(modules):
        assert list(data["observability"]) == OBSERVABILITY_KEYS
        assert data["observability"] == {
            "role_arn": f"arn:aws:iam::{account}:role/SymbolObservability-{org}",
            "account_id": account, "region": "us-east-1"}
    else:
        assert data["observability"] is None
    if "monitoring" in modules:
        assert list(data["monitoring"]) == MONITORING_KEYS
        assert data["monitoring"] == {
            "queue_url": f"https://sqs.us-east-1.amazonaws.com/{account}/symbol-monitoring-{org}",
            "rule_name": f"symbol-monitoring-{org}"}
        assert "RegionalForwarderTemplateUrl" in outputs
    else:
        assert data["monitoring"] is None
        assert "RegionalForwarderTemplateUrl" not in outputs
    if "security" in modules:
        assert data["security"] == {"managed_policies": ["SecurityAudit", "ViewOnlyAccess"]}
    else:
        assert data["security"] is None

    assert outputs["SymbolConnectionSummary"]


@pytest.mark.parametrize("variant", sorted(FINOPS_VARIANTS))
def test_finops_role_can_read_what_the_reader_lists(stack, variant):
    """Cross-check with aws_extractor.py / preflight: the role's s3:prefix condition and
    GetObject resource must cover the reader's listing prefix, the data files and the
    manifest that AWS Data Exports writes."""
    ev = build(stack, ("finops",), variant)
    finops = cfn.decode_connection_code(render_outputs(ev, stack)["SymbolConnectionCode"])["finops"]
    path = reader_export_path(finops["prefix"], finops["export_name"])
    name = finops["export_name"]
    data_key = f"{path}data/BILLING_PERIOD=2026-09/{name}-00001.csv.gz"
    manifest_key = f"{path}metadata/BILLING_PERIOD=2026-09/{name}-Manifest.json"

    role = ev.resolve(stack["Resources"]["FinOpsRole"]["Properties"])
    statements = {s["Sid"]: s for s in role["Policies"][0]["PolicyDocument"]["Statement"]}
    bucket_arn = f"arn:aws:s3:::{finops['bucket']}"

    listing = statements["ListExportPath"]
    assert listing["Resource"] == bucket_arn
    patterns = listing["Condition"]["StringLike"]["s3:prefix"]
    assert any(fnmatch.fnmatchcase(path, p) for p in patterns), (path, patterns)
    # A neighbouring export under the same prefix is NOT listable.
    assert not any(fnmatch.fnmatchcase(path.rstrip("/") + "-old/", p) for p in patterns)

    reading = statements["ReadExportFiles"]
    for key in (data_key, manifest_key):
        assert fnmatch.fnmatchcase(f"{bucket_arn}/{key}", reading["Resource"]), key
    assert statements["LocateExportBucket"]["Resource"] == bucket_arn

    if variant == "created":
        export = ev.resolve(stack["Resources"]["FocusExport"]["Properties"])["Export"]
        dest = export["DestinationConfigurations"]["S3Destination"]
        # AWS writes s3://<S3Bucket>/<S3Prefix>/<Name>/data/BILLING_PERIOD=YYYY-MM/...
        assert reader_export_path(dest["S3Prefix"], export["Name"]) == path
        assert dest["S3Bucket"] == finops["bucket"]


def test_reader_path_matches_connections_service_when_available():
    """Uses the real preflight function when the DAAS checkout sits next to this repo."""
    import importlib
    import sys
    from pathlib import Path

    service = cfn.AWS_DIR.parents[1] / "DAAS" / "backend" / "connections-service"
    if not (service / "app" / "preflight" / "aws.py").exists():
        pytest.skip("connections-service not checked out next to symbol-cloud-connect")
    sys.path.insert(0, str(service))
    try:
        module = importlib.import_module("app.preflight.aws")
    except Exception as exc:  # noqa: BLE001 - its own dependencies may be absent here
        pytest.skip(f"cannot import app.preflight.aws: {exc}")
    finally:
        sys.path.remove(str(service))
    for prefix, name in [("symbol-focus", "symbol-focus-2"), ("", "acme-focus"),
                         ("billing/focus", "acme-focus")]:
        assert module.export_path(prefix, name) == reader_export_path(prefix, name)
    assert Path(module.__file__).exists()


def test_worst_case_code_size(stack):
    """Longest org id, all modules, the longest discovery problem text."""
    long_problem = {**NOT_FOUND, "Problem": "x" * 300}
    params = dict(SYMBOL_PARAMS, SymbolOrgId="o" * 44)
    ev = cfn.Evaluator(stack, params, attributes={"IdentityCenterDiscovery": long_problem})
    code = render_outputs(ev, stack)["SymbolConnectionCode"]
    assert len(code) <= 4096
    assert cfn.decode_connection_code(code)["org"] == "o" * 44


@pytest.mark.parametrize("transform", ["unpadded", "urlsafe", "wrapped"])
def test_decoder_accepts_contract_variants(stack, transform):
    code = render_outputs(build(stack, MODULE_ORDER), stack)["SymbolConnectionCode"]
    body = code[len("SYMBOL-AWS-1."):]
    if transform == "unpadded":
        body = body.rstrip("=")
    elif transform == "urlsafe":
        body = body.replace("+", "-").replace("/", "_").rstrip("=")
    else:
        body = "\n  ".join(body[i:i + 64] for i in range(0, len(body), 64))
    assert cfn.decode_connection_code("SYMBOL-AWS-1." + body)["v"] == 1


def test_code_carries_no_secret_and_no_external_id(stack):
    code = render_outputs(build(stack, MODULE_ORDER), stack)["SymbolConnectionCode"]
    text = json.dumps(cfn.decode_connection_code(code))
    assert SYMBOL_PARAMS["ExternalId"] not in text
    assert SYMBOL_PARAMS["SymbolPrincipalArn"] not in text
