"""Static checks on the template structure: trust, least privilege, retention, parameters,
event pattern and Data Export settings."""
import re
from pathlib import Path

import pytest

import cfn
from conftest import SYMBOL_PARAMS
from test_connection_code import MODULE_ORDER, build

#: Actions allowed on Resource "*" because the service offers no resource-level
#: permission for them (Service Authorization Reference). Anything else must be scoped.
STAR_RESOURCE_ACTIONS = {
    "sso:ListInstances",
    "tag:GetResources",
    "cost-optimization-hub:ListEnrollmentStatuses",
    "cost-optimization-hub:ListRecommendations",
    "cost-optimization-hub:GetRecommendation",
    "organizations:ListAccounts",
    "organizations:DescribeOrganization",
    "ec2:DescribeRegions",
}

#: The detail-types monitoring-service's parse_aws dispatches on and the recommended rule
#: selects ("Config Configuration Item Change" is parsed but deliberately not selected).
EVENT_DETAIL_TYPES = [
    "AWS API Call via CloudTrail",
    "GuardDuty Finding",
    "Security Hub Findings - Imported",
    "Config Rules Compliance Change",
]

#: FOCUS 1.0 with AWS columns (Data Exports table dictionary).
FOCUS_1_0_AWS_COLUMNS = {
    "AvailabilityZone", "BilledCost", "BillingAccountId", "BillingAccountName",
    "BillingCurrency", "BillingPeriodEnd", "BillingPeriodStart", "ChargeCategory",
    "ChargeClass", "ChargeDescription", "ChargeFrequency", "ChargePeriodEnd",
    "ChargePeriodStart", "CommitmentDiscountCategory", "CommitmentDiscountId",
    "CommitmentDiscountName", "CommitmentDiscountStatus", "CommitmentDiscountType",
    "ConsumedQuantity", "ConsumedUnit", "ContractedCost", "ContractedUnitPrice",
    "EffectiveCost", "InvoiceIssuerName", "ListCost", "ListUnitPrice", "PricingCategory",
    "PricingQuantity", "PricingUnit", "ProviderName", "PublisherName", "RegionId",
    "RegionName", "ResourceId", "ResourceName", "ResourceType", "ServiceCategory",
    "ServiceName", "SkuId", "SkuPriceId", "SubAccountId", "SubAccountName", "Tags",
    "x_CostCategories", "x_Discounts", "x_Operation", "x_ServiceCode", "x_UsageType",
}

CONTRACT_PARAMETERS = {
    "SymbolOrgId": None, "SetupSessionId": None, "TemplateVersion": "aws-v1.0.0",
    "SymbolPrincipalArn": None, "ExternalId": None, "SymbolEgressCidrs": "",
    "EnableSignin": "true", "EnableFinops": "true", "EnableMonitoring": "true",
    "EnableSecurity": "true", "IdentityCenterRegion": "", "IdentityCenterStartUrl": "",
    "CreateFocusExport": "true", "ExistingExportBucket": "", "ExistingExportPrefix": "",
    "ExistingExportName": "", "ExportBucketKmsKeyArn": "",
    "MonitoringQueueRetentionSeconds": "345600",
}


def all_enabled(stack, **overrides):
    params = dict(SYMBOL_PARAMS, ExportBucketKmsKeyArn=(
        "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"))
    params.update(overrides)
    return cfn.Evaluator(stack, params, attributes={"IdentityCenterDiscovery": {
        "Region": "eu-west-1", "StartUrl": "https://d-1234567890.awsapps.com/start",
        "Problem": "", "InstanceArn": ""}})


def roles(ev, template):
    for logical_id, resource in template["Resources"].items():
        if resource["Type"] == "AWS::IAM::Role" and ev.resource_enabled(logical_id):
            yield logical_id, ev.resolve(resource["Properties"])


def statements(role):
    for policy in role.get("Policies", []):
        yield from policy["PolicyDocument"]["Statement"]


def as_list(value):
    return value if isinstance(value, list) else [value]


# ---------------------------------------------------------------------------- parameters
def test_parameters_are_exactly_the_contract(stack):
    params = stack["Parameters"]
    assert set(params) == set(CONTRACT_PARAMETERS)
    for name, default in CONTRACT_PARAMETERS.items():
        if default is None:
            assert "Default" not in params[name], name
        else:
            assert str(params[name]["Default"]) == default, name


def test_no_parameter_is_noecho(stack, forwarder):
    for template in (stack, forwarder):
        for name, spec in template["Parameters"].items():
            assert not spec.get("NoEcho"), name


def test_every_parameter_is_in_the_console_form(stack, forwarder):
    for template in (stack, forwarder):
        interface = template["Metadata"]["AWS::CloudFormation::Interface"]
        grouped = [p for g in interface["ParameterGroups"] for p in g["Parameters"]]
        assert sorted(grouped) == sorted(template["Parameters"])
        assert set(interface["ParameterLabels"]) == set(template["Parameters"])
    labels = [g["Label"]["default"] for g in
              stack["Metadata"]["AWS::CloudFormation::Interface"]["ParameterGroups"]]
    assert labels[0] == "Symbol (pre-filled - do not change)"
    assert labels[1:] == ["Modules", "Sign-in (IAM Identity Center)",
                          "FinOps (cost and usage)", "Monitoring"]


def test_string_parameters_have_validation(stack):
    for name, spec in stack["Parameters"].items():
        if spec["Type"] == "String":
            assert "AllowedPattern" in spec or "AllowedValues" in spec, name
            if "AllowedPattern" in spec:
                assert spec.get("ConstraintDescription"), name


@pytest.mark.parametrize("name,good,bad", [
    ("SymbolOrgId", ["2", "acme_corp-1", "o" * 44], ["", "a b", "o" * 45, 'a"b']),
    ("SetupSessionId", ["0b8f9a7e-3c2d-4e1f-9a8b-7c6d5e4f3a2b"], ["0b8f9a7e", ""]),
    ("TemplateVersion", ["aws-v1.0.0", "aws-v12.3.45"], ["oci-v1.0.0", "aws-v1.0"]),
    ("SymbolPrincipalArn", ["arn:aws:iam::999988887777:role/symbol-cloud-connector",
                            "arn:aws:iam::999988887777:user/dev",
                            "arn:aws-us-gov:iam::999988887777:role/path/x"],
     ["arn:aws:iam::99998888777:role/x", "arn:aws:sts::999988887777:assumed-role/x/y", "*"]),
    ("ExternalId", [SYMBOL_PARAMS["ExternalId"], "ab", "a:b/c@d"], ["a", 'a"b', "a b", "x" * 1225]),
    ("SymbolEgressCidrs", ["", "196.203.252.10/32", "1.2.3.0/24,5.6.7.8/32",
                           "2001:db8::/48", "1.2.3.4/32,2001:db8::/48"],
     ["1.2.3.4", "1.2.3.4/32, 5.6.7.8/32", "1.2.3.4/32,", "a"]),
    ("IdentityCenterRegion", ["", "eu-west-1", "us-gov-west-1", "ap-southeast-2"],
     ["EU-WEST-1", "eu-west", "eu-west-1a"]),
    ("IdentityCenterStartUrl", ["", "https://d-1234567890.awsapps.com/start",
                                "https://acme.awsapps.com/start/"],
     ["http://acme.awsapps.com/start", "https://acme.example.com/start",
      'https://a".awsapps.com/start']),
    ("ExistingExportBucket", ["", "acme-cur", "my.bucket.name"], ["A", "-bad", 'a"b']),
    ("ExistingExportPrefix", ["", "symbol-focus", "billing/focus", "a"],
     ["/billing", "billing/", 'bil"ling', "bil\\ling"]),
    ("ExistingExportName", ["", "acme-focus", "Acme_Focus_1"], ["acme focus", "a/b", "a.b"]),
    ("ExportBucketKmsKeyArn", ["", "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
                               "arn:aws:kms:eu-west-1:111122223333:key/mrk-1234abcd12ab34cd56ef1234567890ab"],
     ["arn:aws:kms:us-east-1:111122223333:alias/x", "key"]),
])
def test_parameter_patterns(stack, name, good, bad):
    pattern = stack["Parameters"][name]["AllowedPattern"]
    for value in good:
        assert re.fullmatch(pattern, value), (name, value)
    for value in bad:
        assert not re.fullmatch(pattern, value), (name, value)


def test_embedded_parameters_cannot_break_the_json(stack):
    """Every parameter that ends up inside the connection code JSON excludes '"' and '\\'."""
    for name in ("SymbolOrgId", "SetupSessionId", "TemplateVersion", "IdentityCenterRegion",
                 "IdentityCenterStartUrl", "ExistingExportBucket", "ExistingExportPrefix",
                 "ExistingExportName"):
        pattern = stack["Parameters"][name]["AllowedPattern"]
        for poison in ('"', "\\", "\n"):
            assert not re.fullmatch(pattern, "a" + poison + "b"), (name, poison)


# ---------------------------------------------------------------------------- rules
@pytest.mark.parametrize("overrides,region,expected", [
    ({}, "us-east-1", []),
    ({}, "eu-west-1", ["StackRegionIsUsEast1"]),
    ({"EnableSignin": "false", "EnableFinops": "false", "EnableMonitoring": "false",
      "EnableSecurity": "false"}, "us-east-1", ["AtLeastOneModule"]),
    ({"CreateFocusExport": "false"}, "us-east-1",
     ["ExistingExportIsComplete", "ExistingExportIsComplete"]),
    ({"CreateFocusExport": "false", "ExistingExportBucket": "b-1"}, "us-east-1",
     ["ExistingExportIsComplete"]),
    ({"CreateFocusExport": "false", "EnableFinops": "false"}, "us-east-1", []),
    ({"IdentityCenterStartUrl": "https://acme.awsapps.com/start"}, "us-east-1",
     ["StartUrlNeedsRegion"]),
    ({"IdentityCenterStartUrl": "https://acme.awsapps.com/start",
      "IdentityCenterRegion": "eu-west-1"}, "us-east-1", []),
])
def test_rules(stack, overrides, region, expected):
    ev = cfn.Evaluator(stack, dict(SYMBOL_PARAMS, **overrides), region=region)
    assert ev.failed_rules() == expected


def test_forwarder_refuses_us_east_1(forwarder):
    params = {"SymbolOrgId": "2",
              "TargetEventBusArn": "arn:aws:events:us-east-1:111122223333:event-bus/default"}
    assert cfn.Evaluator(forwarder, params, region="us-east-1").failed_rules() == ["NotInUsEast1"]
    assert cfn.Evaluator(forwarder, params, region="eu-west-1").failed_rules() == []


# ---------------------------------------------------------------------------- IAM
@pytest.mark.parametrize("cidrs", ["196.203.252.10/32,2001:db8::/48", ""])
def test_symbol_roles_trust_and_source_ip(stack, cidrs):
    ev = all_enabled(stack, SymbolEgressCidrs=cidrs)
    symbol_roles = {"FinOpsRole", "ObservabilityRole"}
    found = set()
    for logical_id, role in roles(ev, stack):
        trust = role["AssumeRolePolicyDocument"]["Statement"]
        assert role["MaxSessionDuration"] == 3600, logical_id
        for statement in trust:
            assert statement["Action"] == "sts:AssumeRole"
            principal = statement["Principal"]
            if "AWS" in principal:
                found.add(logical_id)
                assert principal == {"AWS": SYMBOL_PARAMS["SymbolPrincipalArn"]}
                # ExternalId on the trust, and NO IP condition there (contract §4.4).
                assert statement["Condition"] == {
                    "StringEquals": {"sts:ExternalId": SYMBOL_PARAMS["ExternalId"]}}
            else:
                assert principal == {"Service": "lambda.amazonaws.com"}
                assert statement["Condition"]["StringEquals"]["aws:SourceAccount"] == "111122223333"
        if logical_id not in symbol_roles:
            continue
        assert role["RoleName"] == {"FinOpsRole": "SymbolFinOps-2",
                                    "ObservabilityRole": "SymbolObservability-2"}[logical_id]
        for statement in statements(role):
            condition = statement.get("Condition", {})
            if statement["Effect"] == "Deny":
                assert cidrs, "the source-IP deny exists only with CIDRs"
                assert condition["NotIpAddress"]["aws:SourceIp"] == cidrs.split(",")
                assert condition["Bool"] == {"aws:ViaAWSService": "false"}
                continue
            if cidrs:
                assert condition["IpAddress"] == {"aws:SourceIp": cidrs.split(",")}, statement["Sid"]
            else:
                assert "IpAddress" not in condition, statement["Sid"]
        has_deny = any(s["Effect"] == "Deny" for s in statements(role))
        assert has_deny == bool(cidrs), logical_id
    assert found == symbol_roles


def test_no_wildcard_resource_except_documented_actions(stack, forwarder):
    for template, ev in ((stack, all_enabled(stack)),
                         (forwarder, cfn.Evaluator(forwarder, {
                             "SymbolOrgId": "2", "TargetEventBusArn":
                             "arn:aws:events:us-east-1:111122223333:event-bus/default"},
                             region="eu-west-1"))):
        for logical_id, role in roles(ev, template):
            for statement in statements(role):
                resources = as_list(statement["Resource"])
                actions = as_list(statement["Action"])
                if statement["Effect"] == "Allow":
                    assert all("*" not in a for a in actions), (logical_id, actions)
                if "*" in resources:
                    if statement["Effect"] == "Deny":
                        assert actions == ["*"] and "NotIpAddress" in statement["Condition"]
                    else:
                        assert set(actions) <= STAR_RESOURCE_ACTIONS, (logical_id, actions)
                elif statement["Effect"] == "Allow":
                    assert all(a != "*" and not a.endswith(":*") for a in actions)


def test_only_read_actions_for_symbol(stack):
    """Symbol's roles hold no write action, apart from consuming its own queue."""
    allowed_writes = {"sqs:DeleteMessage", "sqs:ChangeMessageVisibility"}
    ev = all_enabled(stack)
    for logical_id, role in roles(ev, stack):
        if logical_id not in ("FinOpsRole", "ObservabilityRole"):
            continue
        for statement in statements(role):
            if statement["Effect"] != "Allow":
                continue
            for action in as_list(statement["Action"]):
                verb = action.split(":", 1)[1]
                assert (action in allowed_writes
                        or re.match(r"(List|Get|Describe|Receive|Decrypt)", verb)), action


def test_security_managed_policies(stack):
    ev = all_enabled(stack)
    role = ev.resolve(stack["Resources"]["ObservabilityRole"]["Properties"])
    assert role["ManagedPolicyArns"] == ["arn:aws:iam::aws:policy/SecurityAudit",
                                         "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
    ev = all_enabled(stack, EnableSecurity="false")
    assert "ManagedPolicyArns" not in ev.resolve(stack["Resources"]["ObservabilityRole"]["Properties"])


def test_kms_decrypt_only_with_key_and_only_through_s3(stack):
    ev = all_enabled(stack)
    role = ev.resolve(stack["Resources"]["FinOpsRole"]["Properties"])
    kms = [s for s in statements(role) if s.get("Sid") == "DecryptExportThroughS3"]
    assert kms and kms[0]["Action"] == "kms:Decrypt"
    assert kms[0]["Condition"]["StringLike"] == {"kms:ViaService": "s3.*.amazonaws.com"}
    ev = all_enabled(stack, ExportBucketKmsKeyArn="")
    role = ev.resolve(stack["Resources"]["FinOpsRole"]["Properties"])
    assert not [s for s in statements(role) if "kms:Decrypt" in as_list(s["Action"])]


def test_discovery_role_is_minimal(stack):
    ev = all_enabled(stack)
    role = ev.resolve(stack["Resources"]["IdentityCenterDiscoveryRole"]["Properties"])
    actions = sorted(a for s in statements(role) for a in as_list(s["Action"]))
    assert actions == ["logs:CreateLogStream", "logs:PutLogEvents", "sso:ListInstances"]
    log_statement = [s for s in statements(role) if s["Sid"] == "WriteOwnLogs"][0]
    assert log_statement["Resource"].endswith(":log-group:/aws/lambda/SymbolIdcDiscovery-2:*")
    assert "ManagedPolicyArns" not in role


def test_discovery_only_when_start_url_empty(stack):
    ev = all_enabled(stack, IdentityCenterStartUrl="https://acme.awsapps.com/start",
                     IdentityCenterRegion="eu-west-1")
    for name in ("IdentityCenterDiscovery", "IdentityCenterDiscoveryFunction",
                 "IdentityCenterDiscoveryRole", "IdentityCenterDiscoveryLogGroup"):
        assert not ev.resource_enabled(name)
    assert all_enabled(stack).resource_enabled("IdentityCenterDiscovery")
    assert not all_enabled(stack, EnableSignin="false").resource_enabled("IdentityCenterDiscovery")


def test_discovery_function_settings(stack):
    resources = stack["Resources"]
    function = resources["IdentityCenterDiscoveryFunction"]["Properties"]
    assert function["Runtime"] == "python3.13"
    assert function["Handler"] == "index.handler"
    assert "ZipFile" in function["Code"]
    log_group = resources["IdentityCenterDiscoveryLogGroup"]["Properties"]
    assert log_group["RetentionInDays"] == 14
    custom = resources["IdentityCenterDiscovery"]
    assert custom["Condition"] == "DiscoverIdentityCenter"
    assert custom["Properties"]["ServiceTimeout"] <= 600


# ---------------------------------------------------------------------------- FinOps
def test_export_bucket_is_retained_private_and_encrypted(stack):
    bucket = stack["Resources"]["FocusExportBucket"]
    assert bucket["DeletionPolicy"] == "Retain"
    assert bucket["UpdateReplacePolicy"] == "Retain"
    props = bucket["Properties"]
    assert props["BucketEncryption"]["ServerSideEncryptionConfiguration"][0][
        "ServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256"
    assert all(props["PublicAccessBlockConfiguration"].values())
    assert len(props["PublicAccessBlockConfiguration"]) == 4
    assert props["OwnershipControls"]["Rules"] == [{"ObjectOwnership": "BucketOwnerEnforced"}]
    ev = all_enabled(stack)
    assert re.fullmatch(r"symbol-focus-111122223333-[0-9a-f]{8}", ev.ref("FocusExportBucket"))


def test_export_bucket_policy(stack):
    ev = all_enabled(stack)
    policy = ev.resolve(stack["Resources"]["FocusExportBucketPolicy"]["Properties"])
    by_sid = {s["Sid"]: s for s in policy["PolicyDocument"]["Statement"]}
    tls = by_sid["DenyInsecureTransport"]
    assert tls["Effect"] == "Deny" and tls["Condition"] == {"Bool": {"aws:SecureTransport": "false"}}
    for sid in ("EnableAWSDataExportsToWriteToS3", "EnableAWSDataExportsToCheckBucketPolicy"):
        statement = by_sid[sid]
        assert statement["Principal"] == {"Service": ["bcm-data-exports.amazonaws.com",
                                                      "billingreports.amazonaws.com"]}
        assert statement["Condition"] == {
            "StringLike": {"aws:SourceArn": [
                "arn:aws:cur:us-east-1:111122223333:definition/*",
                "arn:aws:bcm-data-exports:us-east-1:111122223333:export/*"]},
            "StringEquals": {"aws:SourceAccount": "111122223333"}}
    assert by_sid["EnableAWSDataExportsToWriteToS3"]["Action"] == "s3:PutObject"
    assert by_sid["EnableAWSDataExportsToCheckBucketPolicy"]["Action"] == "s3:GetBucketPolicy"


def test_focus_export_definition(stack):
    resource = stack["Resources"]["FocusExport"]
    assert resource["DependsOn"] == "FocusExportBucketPolicy"
    ev = all_enabled(stack)
    export = ev.resolve(resource["Properties"])["Export"]
    assert export["Name"] == "symbol-focus-2"
    assert re.fullmatch(r"[0-9A-Za-z\-_]{1,128}", export["Name"])
    query = " ".join(export["DataQuery"]["QueryStatement"].split())
    match = re.fullmatch(r"SELECT (.+) FROM FOCUS_1_0_AWS", query)
    assert match, query
    columns = [c.strip() for c in match.group(1).split(",")]
    assert len(columns) == len(set(columns))
    assert set(columns) == FOCUS_1_0_AWS_COLUMNS
    assert "TableConfigurations" not in export["DataQuery"]  # none exist for FOCUS_1_0_AWS
    destination = export["DestinationConfigurations"]["S3Destination"]
    assert destination["S3OutputConfigurations"] == {
        "Format": "TEXT_OR_CSV", "Compression": "GZIP", "OutputType": "CUSTOM",
        "Overwrite": "OVERWRITE_REPORT"}
    assert destination["S3Prefix"] == "symbol-focus"
    assert destination["S3Region"] == "us-east-1"
    assert destination["S3BucketOwner"] == "111122223333"
    assert export["RefreshCadence"] == {"Frequency": "SYNCHRONOUS"}


def test_existing_export_creates_no_bucket(stack):
    ev = all_enabled(stack, CreateFocusExport="false", ExistingExportBucket="acme-cur",
                     ExistingExportName="acme-focus")
    for name in ("FocusExportBucket", "FocusExportBucketPolicy", "FocusExport"):
        assert not ev.resource_enabled(name)
    assert ev.resource_enabled("FinOpsRole")


# ---------------------------------------------------------------------------- monitoring
def test_event_patterns(stack, forwarder):
    main = stack["Resources"]["MonitoringRule"]["Properties"]
    fwd = forwarder["Resources"]["ForwarderRule"]["Properties"]
    assert main["EventPattern"] == {"detail-type": EVENT_DETAIL_TYPES}
    assert fwd["EventPattern"] == main["EventPattern"]
    assert main["EventBusName"] == fwd["EventBusName"] == "default"


def test_event_pattern_matches_monitoring_service_when_available():
    parse = (cfn.AWS_DIR.parents[1] / "DAAS" / "backend" / "monitoring-service" / "app"
             / "pipeline" / "parse.py")
    if not parse.exists():
        pytest.skip("monitoring-service not checked out next to symbol-cloud-connect")
    source = parse.read_text(encoding="utf-8")
    constants = dict(re.findall(r'^(_AWS_[A-Z_]+) = "([^"]+)"', source, re.M))
    parsed = {constants[k] for k in ("_AWS_CLOUDTRAIL", "_AWS_GUARDDUTY", "_AWS_SECURITYHUB",
                                     "_AWS_CONFIG_COMPLIANCE")}
    assert parsed == set(EVENT_DETAIL_TYPES)
    # Parsed, but documented as deliberately NOT selected (fires on every resource change).
    assert constants["_AWS_CONFIG_ITEM"] not in EVENT_DETAIL_TYPES


def test_queue_and_policy(stack):
    ev = all_enabled(stack)
    queue = ev.resolve(stack["Resources"]["MonitoringQueue"]["Properties"])
    dlq = ev.resolve(stack["Resources"]["MonitoringDeadLetterQueue"]["Properties"])
    assert queue["QueueName"] == "symbol-monitoring-2"
    assert dlq["QueueName"] == "symbol-monitoring-2-dlq"
    assert queue["SqsManagedSseEnabled"] is True and dlq["SqsManagedSseEnabled"] is True
    assert queue["MessageRetentionPeriod"] == "345600"
    assert queue["RedrivePolicy"] == {
        "deadLetterTargetArn": "arn:aws:sqs:us-east-1:111122223333:symbol-monitoring-2-dlq",
        "maxReceiveCount": 5}
    assert queue["ReceiveMessageWaitTimeSeconds"] == 20
    policy = ev.resolve(stack["Resources"]["MonitoringQueuePolicy"]["Properties"])
    send = policy["PolicyDocument"]["Statement"][0]
    assert send["Principal"] == {"Service": "events.amazonaws.com"}
    assert send["Action"] == "sqs:SendMessage"
    assert send["Condition"] == {"ArnEquals": {
        "aws:SourceArn": "arn:aws:events:us-east-1:111122223333:rule/symbol-monitoring-2"}}
    rule = ev.resolve(stack["Resources"]["MonitoringRule"]["Properties"])
    assert rule["Targets"] == [{"Id": "symbol-monitoring-queue",
                                "Arn": "arn:aws:sqs:us-east-1:111122223333:symbol-monitoring-2"}]
    role = ev.resolve(stack["Resources"]["ObservabilityRole"]["Properties"])
    sqs = [s for s in statements(role) if s.get("Sid") == "ConsumeSymbolEventQueue"][0]
    assert sorted(sqs["Action"]) == sorted(["sqs:ReceiveMessage", "sqs:DeleteMessage",
                                            "sqs:GetQueueAttributes",
                                            "sqs:ChangeMessageVisibility"])
    assert sqs["Resource"] == "arn:aws:sqs:us-east-1:111122223333:symbol-monitoring-2"


def test_no_default_bus_policy_is_created(stack):
    """Same-account cross-Region delivery needs only the sender's IAM role (see README)."""
    kinds = {r["Type"] for r in stack["Resources"].values()}
    assert "AWS::Events::EventBusPolicy" not in kinds


def test_forwarder(forwarder):
    ev = cfn.Evaluator(forwarder, {
        "SymbolOrgId": "2",
        "TargetEventBusArn": "arn:aws:events:us-east-1:111122223333:event-bus/default"},
        region="eu-west-1")
    role = ev.resolve(forwarder["Resources"]["ForwarderRole"]["Properties"])
    trust = role["AssumeRolePolicyDocument"]["Statement"][0]
    assert trust["Principal"] == {"Service": "events.amazonaws.com"}
    assert trust["Condition"] == {
        "ArnEquals": {"aws:SourceArn": "arn:aws:events:eu-west-1:111122223333:rule/symbol-monitoring-2"},
        "StringEquals": {"aws:SourceAccount": "111122223333"}}
    statement = role["Policies"][0]["PolicyDocument"]["Statement"]
    assert statement == [{"Sid": "PutEventsOnTheUsEast1DefaultBus", "Effect": "Allow",
                          "Action": "events:PutEvents",
                          "Resource": "arn:aws:events:us-east-1:111122223333:event-bus/default"}]
    rule = ev.resolve(forwarder["Resources"]["ForwarderRule"]["Properties"])
    assert rule["Name"] == "symbol-monitoring-2"
    assert rule["Targets"][0]["RoleArn"].startswith("arn:aws:iam::111122223333:role/")
    bad = "arn:aws:events:eu-west-1:111122223333:event-bus/default"
    assert not re.fullmatch(forwarder["Parameters"]["TargetEventBusArn"]["AllowedPattern"], bad)


def test_template_version_is_consistent(stack):
    version = stack["Parameters"]["TemplateVersion"]["Default"]
    assert version in stack["Description"]
    forwarder_text = cfn.FORWARDER.read_text(encoding="utf-8")
    assert version in forwarder_text
    changelog = (cfn.AWS_DIR / "CHANGELOG.md").read_text(encoding="utf-8")
    assert f"## {version}" in changelog


def test_every_resource_is_tagged_where_supported(stack):
    taggable = {"AWS::IAM::Role", "AWS::S3::Bucket", "AWS::SQS::Queue",
                "AWS::Lambda::Function", "AWS::BCMDataExports::Export"}
    for logical_id, resource in stack["Resources"].items():
        if resource["Type"] in taggable:
            keys = {t["Key"] for t in resource["Properties"]["Tags"]}
            assert {"symbol-managed", "symbol-org", "symbol-template"} <= keys, logical_id


def test_templates_are_ascii_and_lf(stack):
    for path in (cfn.STACK, cfn.FORWARDER):
        raw = Path(path).read_bytes()
        assert b"\r\n" not in raw
        raw.decode("ascii")
