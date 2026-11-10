"""Cross-checks of the Azure template outside Terraform (pytest).

The connection code is the contract between this repository and connections-service, and
it is the one thing a mistake in would be found only by a customer. So:

1. The code `outputs.tf` builds satisfies CLOUD-SETUP-CONTRACT-V2 §6.7 exactly, decoded
   the way Symbol decodes it; and, when connections-service is checked out next to this
   repository, ITS OWN adapter accepts it. A schema both sides merely believe in is how
   the two drift.
2. Every role this template assigns is one connections-service's manual guide also grants.
   A guide that granted less would pass its own setup and fail the same preflight.
3. The names the template creates are the names the adapter expects.
4. No role assignment is ever made at management-group scope: azure-v1 is a
   subscription-scoped template, and a widened scope would be invisible in the code.

This file reads the Terraform SOURCE rather than running it: `terraform test` with the
azuread provider needs either real credentials or mocks for every Graph call, and the
properties worth pinning here are structural. `azure-ci.yml` runs fmt, validate, tflint
and checkov for the rest.
"""
from __future__ import annotations

import base64
import json
import re
import sys
from pathlib import Path

import pytest

AZURE_DIR = Path(__file__).resolve().parents[1]
PREFIX = "SYMBOL-AZURE-2."
CODE_VERSION = 2
MAX_LENGTH = 16384

#: Contract §6.7. Every key the code may carry, and nothing else.
TOP_KEYS = {"v", "org", "session", "template", "modules", "tenant", "subscription",
            "app", "finops", "observability"}
APP_KEYS = {"client_id", "object_id", "secret", "expires"}
FINOPS_KEYS = {"storage_account", "container", "directory", "export_name", "export_created"}
OBSERVABILITY_KEYS = {"eventhub_namespace", "eventhub_name", "consumer_group",
                      "monitoring_enabled", "security_enabled"}

#: The roles the template assigns, read back out of the Terraform.
EXPECTED_ROLES = {
    "Storage Blob Data Reader",
    "Cost Management Reader",
    "Reader",
    "Security Reader",
    "Monitoring Reader",
    "Azure Event Hubs Data Receiver",
}


def _read(*parts: str) -> str:
    return (AZURE_DIR.joinpath(*parts)).read_text(encoding="utf-8")


def _all_terraform() -> str:
    return "\n".join(path.read_text(encoding="utf-8")
                     for path in sorted(AZURE_DIR.rglob("*.tf")))


def _code_only(text: str) -> str:
    """The Terraform with its comments removed.

    Several of the checks below are "this string appears nowhere" -- and the comments are
    where the template EXPLAINS why it does not do the thing. Matching those would make
    the explanation itself the failure.
    """
    return "\n".join(line for line in text.splitlines()
                      if not line.lstrip().startswith("#"))


# -- 1. the connection code ------------------------------------------------------------


def test_the_code_prefix_and_version_match_the_contract():
    outputs = _read("outputs.tf")
    assert 'connection_code   = "SYMBOL-AZURE-2.${local.connection_b64url}"' in outputs
    assert "v        = 2" in outputs
    assert "<= 16384" in outputs, "the size precondition is missing"


def test_the_code_is_unpadded_base64url():
    """Symbol's decoder accepts both, but the template must print the documented form."""
    outputs = _read("outputs.tf")
    assert 'replace(replace(replace(base64encode(jsonencode(local.connection))' in outputs
    assert '"+", "-"' in outputs and '"/", "_"' in outputs and '"/=+$/", ""' in outputs


def test_the_code_output_is_sensitive():
    """It carries two client secrets: a non-sensitive output would print them in every plan."""
    outputs = _read("outputs.tf")
    block = outputs.split('output "symbol_connection_code"', 1)[1].split("\noutput ", 1)[0]
    assert "sensitive   = true" in block


def test_the_summary_output_carries_no_secret():
    """It is printed to the terminal unredacted, so it must name identifiers only."""
    outputs = _read("outputs.tf")
    block = outputs.split('output "symbol_connection_summary"', 1)[1]
    assert "credentials" not in block
    assert "secret" not in block.lower() or "Secrets expire" in block


def test_every_key_of_the_code_is_in_the_contract():
    outputs = _read("outputs.tf")
    connection = outputs.split("connection = {", 1)[1].split("\n  }\n", 1)[0]
    keys = set(re.findall(r"^\s{4}([a-z_]+)\s*=", connection, re.MULTILINE))
    unknown = keys - TOP_KEYS
    assert not unknown, f"keys not in contract §6.7: {sorted(unknown)}"
    assert {"v", "org", "session", "template", "modules", "tenant", "subscription",
            "app"} <= keys


def test_a_disabled_module_is_null_not_absent():
    """Symbol tells "off" from "missing" by the null; an absent block is a bad_format."""
    outputs = _read("outputs.tf")
    assert "finops = var.enable_finops ? {" in outputs
    assert "} : null" in outputs
    assert "observability = local.needs_observability_identity ? {" in outputs


def test_a_security_only_code_carries_no_event_pipe():
    """Symbol refuses a namespace no module was asked to read."""
    outputs = _read("outputs.tf")
    assert "eventhub_namespace = var.enable_monitoring ? local.eventhub_namespace_final : null" in outputs
    assert "eventhub_name      = var.enable_monitoring ? local.eventhub_name_final : null" in outputs
    assert "consumer_group     = var.enable_monitoring ? local.consumer_group : null" in outputs


def test_the_guids_are_lower_cased_in_the_code():
    """``azure-subscription:<guid>`` is a unique index: one case, or one subscription twice."""
    outputs = _read("outputs.tf")
    assert "tenant       = lower(var.tenant_id)" in outputs
    assert "subscription = lower(var.subscription_id)" in outputs


# -- 2. the roles ----------------------------------------------------------------------


def test_the_template_assigns_exactly_the_documented_roles():
    terraform = _all_terraform()
    assigned = set(re.findall(r'role_definition_name = "([^"]+)"', terraform))
    assigned |= set(re.findall(r'"(Reader|Security Reader|Monitoring Reader)"\s*=', terraform))
    assert assigned == EXPECTED_ROLES, f"unexpected: {sorted(assigned ^ EXPECTED_ROLES)}"


def test_no_role_is_assigned_at_management_group_scope():
    """azure-v1 is subscription-scoped; a widened scope would not show in the code."""
    terraform = _code_only(_all_terraform())
    assert "managementGroups" not in terraform
    assert "management_group" not in terraform


def test_the_blob_role_is_scoped_to_the_account_and_says_why():
    """Container scope is better and the provider cannot finish it.

    azure-v1.0.1 scoped this to the container; the provider created the assignment and
    then polled thirty minutes for it to "finish replicating" before timing out, while
    the subscription-scoped assignment beside it took 32 seconds. The reason has to stay
    next to the code, or the next reader narrows the scope again and loses another half
    hour finding out why.
    """
    finops = _read("modules", "finops", "main.tf")
    assert re.search(r"scope\s*=\s*local\.storage_account_id", finops)
    assert "THIRTY" in finops or "thirty minutes" in finops
    # The wider scope is only harmless when we made the account; say so where it is read.
    assert "create_export = false" in finops


def test_the_event_hub_role_is_scoped_to_the_hub():
    monitoring = _read("modules", "monitoring", "main.tf")
    assert "scope                = local.eventhub_id" in monitoring


def test_every_assignment_names_a_service_principal():
    """Without principal_type, Azure guesses, and a fresh principal can race the lookup."""
    terraform = _all_terraform()
    assignments = terraform.count('resource "azurerm_role_assignment"')
    assert assignments >= 3
    assert terraform.count('principal_type       = "ServicePrincipal"') == assignments


# -- 3. the identities -----------------------------------------------------------------


def test_the_applications_are_single_tenant_and_hold_no_graph_permission():
    identity = _read("modules", "identity", "main.tf")
    assert 'sign_in_audience = "AzureADMyOrg"' in identity
    # required_resource_access is how a Graph permission is declared. There is none.
    assert "required_resource_access" not in identity
    assert "app_role_assignment_required = false" in identity


def test_the_secret_is_only_replaced_by_an_explicit_rotation():
    """A template that minted one on every apply would cut Symbol's access each time."""
    identity = _read("modules", "identity", "main.tf")
    assert "rotate_when_changed" in identity
    assert 'lookup(var.secret_rotation_ids, each.key, "initial")' in identity


def test_the_expiry_is_absolute_not_relative():
    """``end_date_relative`` is recomputed on every plan and shows a diff that is not one."""
    identity = _read("modules", "identity", "main.tf")
    assert "end_date       = time_offset.secret[each.key].rfc3339" in identity
    assert "end_date_relative" not in _code_only(identity)


def test_the_admin_owns_both_applications():
    """Without an owner, an application created by a non-privileged user is unmanageable."""
    identity = _read("modules", "identity", "main.tf")
    assert identity.count("owners") >= 2
    assert "owner_object_id" in identity


# -- 4. names and refusals --------------------------------------------------------------


def test_the_names_are_the_ones_the_adapter_expects():
    """Whitespace-insensitive: `terraform fmt` owns the alignment, not this test."""
    main = _read("main.tf")
    for key, value in (("export_container", "symbol-focus"),
                       ("export_directory", "symbol-focus"),
                       ("eventhub_name", "symbol-activity"),
                       ("consumer_group", "symbol-monitoring"),
                       ("diagnostic_name", "symbol-activity-log")):
        assert re.search(r"^\s+%s\s*=\s*\"%s\"$" % (key, value), main, re.MULTILINE), key


def test_destroy_supplies_the_variables_terraform_validates():
    """`--destroy` carries no session and no release, and both are validated.

    `destroy_mode` bypasses the lifecycle PRECONDITIONS only; a variable validation
    still runs, so an empty setup_session_id made terraform refuse the var file and the
    revoke could not run at all. Pinned because the destroy path has no happy-path test
    anywhere else -- it is only ever exercised when something has already gone wrong.
    """
    script = (AZURE_DIR / "symbol-setup.sh").read_text(encoding="utf-8")
    # Split on the closing `fi` at its own indentation: a bare "fi" also matches
    # inside "var file", which truncates the block and makes this test lie.
    opened = script.split('if [[ "${DESTROY}" == "true" ]]; then', 1)[1]
    destroy = opened.split("\n  fi", 1)[0]
    assert 'SESSION="${SESSION:-' in destroy
    assert 'TEMPLATE="${TEMPLATE:-' in destroy
    assert 'MODULES="${MODULES:-' in destroy
    # And they must satisfy variables.tf, or the var file is refused.
    assert re.search(r'SESSION:-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', destroy)
    assert re.search(r"TEMPLATE:-azure-v\d+\.\d+\.\d+", destroy)


def test_the_namespace_is_standard_so_a_consumer_group_can_exist():
    """Basic allows exactly one consumer group ($Default) -- the one arrangement refused."""
    monitoring = _read("modules", "monitoring", "main.tf")
    assert 'sku      = "Standard"' in monitoring


def test_the_hub_is_replaced_with_its_namespace():
    """A replaced namespace comes back empty, and the hub has to go with it.

    Changing the region replaces the namespace, but the provider plans the hub as an
    in-place update -- namespace_id is only "known after apply" -- and that update dies
    on `partition_count cannot be decreased`, leaving Terraform believing in a hub that
    no longer exists inside a namespace rebuilt without it.
    """
    monitoring = _read("modules", "monitoring", "main.tf")
    hub = monitoring.split('resource "azurerm_eventhub" "activity"', 1)[1]
    hub = hub.split("\nresource ", 1)[0]
    assert "replace_triggered_by" in hub
    assert "azurerm_eventhub_namespace.symbol[0]" in hub
    # And the consumer group must be ordered after the hub, or it lands on nothing.
    assert "depends_on = [azurerm_eventhub.activity]" in monitoring


def test_only_the_categories_the_parser_understands_are_streamed():
    monitoring = _read("modules", "monitoring", "main.tf")
    categories = set(re.findall(r'category = "([^"]+)"', monitoring))
    assert categories == {"Administrative", "Security", "Policy"}


def test_the_template_never_enables_a_defender_plan():
    """A paid plan turned on by a wizard is a bill nobody agreed to."""
    terraform = _code_only(_all_terraform())
    assert "Microsoft.Security/pricings" not in terraform
    assert "azurerm_security_center_subscription_pricing" not in terraform


def test_the_export_is_focus_and_not_actualcost():
    finops = _read("modules", "finops", "main.tf")
    assert '"FocusCost"' in finops
    assert '"ActualCost"' not in finops
    assert '"dataVersion" = "1.0"' in finops or '"dataVersion": "1.0"' in finops or \
           'dataVersion = "1.0"' in finops


def test_the_storage_account_refuses_public_blobs():
    finops = _read("modules", "finops", "main.tf")
    assert "allow_nested_items_to_be_public = false" in finops
    assert re.search(r'min_tls_version\s*=\s*"TLS1_2"', finops)


def test_the_storage_account_keeps_shared_keys_and_says_why():
    """azure-v1.0.0 set this false and the account could not finish being created.

    The azurerm provider polls the blob data plane after create, with the account key.
    A future edit that turns it off again brings the orphaned-account bug back, so the
    reason has to stay next to the setting.
    """
    finops = _read("modules", "finops", "main.tf")
    assert re.search(r"shared_access_key_enabled\s*=\s*true", finops)
    assert "KeyBasedAuthenticationNotPermitted" in finops
    # And Symbol still reads it as an identity, not with a key.
    assert '"Storage Blob Data Reader"' in finops


# -- 5. the backend's own decoder, when it is checked out --------------------------------


CONNECTIONS = AZURE_DIR.parents[2] / "DAAS" / "backend" / "connections-service"


def _sample_code() -> str:
    """A code of the shape outputs.tf builds, encoded the way it encodes."""
    document = {
        "v": 2, "org": "4", "session": "11111111-2222-3333-4444-555555555555",
        "template": "azure-v1.0.0", "modules": ["finops", "monitoring", "security"],
        "tenant": "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",
        "subscription": "cccccccc-4444-5555-6666-dddddddddddd",
        "app": {
            "finops": {"client_id": "11112222-3333-4444-5555-666677778888",
                       "object_id": "aaaa1111-2222-3333-4444-555566667777",
                       "secret": "Fin~Ops.Secret-Value0123456789abcdef",
                       "expires": "2027-11-10T09:00:00Z"},
            "observability": {"client_id": "99990000-aaaa-bbbb-cccc-ddddeeeeffff",
                              "object_id": "bbbb8888-9999-0000-1111-222233334444",
                              "secret": "Obs~erv.Secret-Value0123456789abcdef",
                              "expires": "2027-11-10T09:00:00Z"},
        },
        "finops": {"storage_account": "symbol0123456789abcd", "container": "symbol-focus",
                   "directory": "symbol-focus", "export_name": "symbol-focus-4",
                   "export_created": True},
        "observability": {"eventhub_namespace": "symbol-0123456789abcd",
                          "eventhub_name": "symbol-activity",
                          "consumer_group": "symbol-monitoring",
                          "monitoring_enabled": True, "security_enabled": True},
    }
    raw = base64.urlsafe_b64encode(json.dumps(document, separators=(",", ":"),
                                              sort_keys=True).encode()).decode().rstrip("=")
    return PREFIX + raw


def test_the_sample_code_decodes_as_the_contract_says():
    raw = _sample_code()
    assert raw.startswith(PREFIX)
    assert len(raw) <= MAX_LENGTH
    body = raw[len(PREFIX):]
    document = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    assert document["v"] == CODE_VERSION
    assert set(document) <= TOP_KEYS
    assert set(document["app"]["finops"]) <= APP_KEYS
    assert set(document["finops"]) <= FINOPS_KEYS
    assert set(document["observability"]) <= OBSERVABILITY_KEYS


@pytest.mark.skipif(not CONNECTIONS.exists(),
                    reason="connections-service is not checked out next to this repository")
def test_connections_service_decodes_the_code_it_will_be_sent():
    """The real decoder, not a copy of its rules. This is what catches a drift."""
    sys.path.insert(0, str(CONNECTIONS))
    try:
        from app.setup import connection_code as cc  # noqa: PLC0415
        from app.setup.providers import azure as adapter  # noqa: PLC0415
    except Exception as exc:  # pragma: no cover - the service's own deps are not ours
        pytest.skip(f"connections-service is not importable here: {exc}")
    finally:
        sys.path.remove(str(CONNECTIONS))

    document = cc.decode(_sample_code(), prefix=adapter.CODE_PREFIX,
                         output_name=adapter.AzureAdapter.code_output_name,
                         version=adapter.CODE_VERSION,
                         max_length=adapter.CODE_MAX_LENGTH)
    assert document["subscription"] == "cccccccc-4444-5555-6666-dddddddddddd"
    # The names this template creates are the ones the adapter publishes.
    assert document["observability"]["consumer_group"] == adapter.CONSUMER_GROUP
    assert document["finops"]["container"] == adapter.EXPORT_CONTAINER
    assert document["observability"]["eventhub_name"] == adapter.EVENTHUB_NAME


@pytest.mark.skipif(not CONNECTIONS.exists(),
                    reason="connections-service is not checked out next to this repository")
def test_the_roles_match_the_manual_guides():
    """The manual guide must leave a subscription in the state this template would."""
    sys.path.insert(0, str(CONNECTIONS))
    try:
        from app.setup.providers import azure as adapter  # noqa: PLC0415
    except Exception as exc:  # pragma: no cover
        pytest.skip(f"connections-service is not importable here: {exc}")
    finally:
        sys.path.remove(str(CONNECTIONS))

    documented = {role for role, _where in adapter.FINOPS_ROLES}
    documented |= set(adapter.OBSERVABILITY_SUBSCRIPTION_ROLES)
    documented.add(adapter.EVENTHUB_ROLE)
    assert documented == EXPECTED_ROLES
