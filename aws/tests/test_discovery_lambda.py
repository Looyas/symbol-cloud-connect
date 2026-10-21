"""Runs the inline Identity Center discovery function (the ZipFile source, as deployed)
against a fake sso-admin client and a fake response URL. No AWS account is used."""
import importlib.util
import json
import sys
import types

import pytest

import cfn

pytest.importorskip("boto3")


class FakeClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code, "Message": "fake"}}


class FakeContext:
    def __init__(self, millis=60_000):
        self.millis = millis

    def get_remaining_time_in_millis(self):
        return self.millis


@pytest.fixture
def lambda_module(stack, tmp_path, monkeypatch):
    source = stack["Resources"]["IdentityCenterDiscoveryFunction"]["Properties"]["Code"]["ZipFile"]
    path = tmp_path / "index.py"
    path.write_text(source, encoding="utf-8")
    spec = importlib.util.spec_from_file_location("symbol_idc_index", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    sent = []

    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def urlopen(request, timeout=None):
        assert request.get_method() == "PUT"
        assert request.headers.get("Content-type") == ""
        sent.append(json.loads(request.data.decode("utf-8")))
        return Response()

    monkeypatch.setattr(module.urllib.request, "urlopen", urlopen)
    module.sent = sent
    return module


def install_regions(module, monkeypatch, answers, regions=None):
    """answers: region -> list of instances | exception code string."""
    calls = []

    class Session:
        def get_available_regions(self, service, partition_name="aws"):
            assert service == "sso-admin"
            return list(regions or answers)

    def client(service, region_name=None, config=None):
        assert service == "sso-admin"
        assert config.connect_timeout <= 5 and config.read_timeout <= 10

        class Client:
            def list_instances(self, **kwargs):
                calls.append(region_name)
                answer = answers.get(region_name, [])
                if isinstance(answer, str):
                    raise FakeClientError(answer)
                return {"Instances": answer}
        return Client()

    monkeypatch.setattr(module.boto3, "session", types.SimpleNamespace(Session=Session))
    monkeypatch.setattr(module.boto3, "client", client)
    return calls


def event(request_type="Create", **props):
    return {
        "RequestType": request_type, "ResponseURL": "https://example.invalid/presigned",
        "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/s/1",
        "RequestId": "r-1", "LogicalResourceId": "IdentityCenterDiscovery",
        "ResourceProperties": {"PreferredRegion": "", "Partition": "aws", **props},
    }


INSTANCE = {"InstanceArn": "arn:aws:sso:::instance/ssoins-72231234567890ab",
            "IdentityStoreId": "d-9067a1b2c3", "Status": "ACTIVE",
            "OwnerAccountId": "111122223333"}


def test_found_in_a_scanned_region(lambda_module, monkeypatch):
    install_regions(lambda_module, monkeypatch, {
        "us-east-1": [], "ap-east-1": "UnrecognizedClientException",
        "eu-west-1": [INSTANCE], "us-west-2": []})
    lambda_module.handler(event(), FakeContext())
    (response,) = lambda_module.sent
    assert response["Status"] == "SUCCESS"
    assert response["PhysicalResourceId"] == "symbol-identity-center-discovery"
    assert response["Data"] == {"Region": "eu-west-1",
                                "StartUrl": "https://d-9067a1b2c3.awsapps.com/start",
                                "InstanceArn": INSTANCE["InstanceArn"], "Problem": ""}


def test_preferred_region_is_tried_alone_first(lambda_module, monkeypatch):
    calls = install_regions(lambda_module, monkeypatch, {
        "us-east-1": [], "eu-central-1": [INSTANCE], "eu-west-1": []})
    lambda_module.handler(event(PreferredRegion="eu-central-1"), FakeContext())
    assert calls == ["eu-central-1"]
    assert lambda_module.sent[0]["Data"]["Region"] == "eu-central-1"


def test_nothing_found_is_success_with_problem(lambda_module, monkeypatch):
    install_regions(lambda_module, monkeypatch, {
        "us-east-1": [], "eu-west-1": [], "me-south-1": "InvalidClientTokenId",
        "af-south-1": "UnrecognizedClientException", "eu-north-1": "AccessDeniedException",
        "sa-east-1": "ThrottlingException"})
    lambda_module.handler(event(), FakeContext())
    response = lambda_module.sent[0]
    assert response["Status"] == "SUCCESS"
    data = response["Data"]
    assert data["Region"] == data["StartUrl"] == data["InstanceArn"] == ""
    assert "No IAM Identity Center instance" in data["Problem"]
    assert "2 not enabled" in data["Problem"]
    assert "denied in eu-north-1" in data["Problem"]
    assert "sa-east-1" in data["Problem"]
    assert '"' not in data["Problem"] and "\\" not in data["Problem"]


def test_inactive_or_malformed_instances_are_ignored(lambda_module, monkeypatch):
    install_regions(lambda_module, monkeypatch, {
        "us-east-1": [{**INSTANCE, "Status": "CREATE_IN_PROGRESS"}],
        "eu-west-1": [{**INSTANCE, "IdentityStoreId": 'd-1"injected'}]})
    lambda_module.handler(event(), FakeContext())
    assert lambda_module.sent[0]["Data"]["StartUrl"] == ""


def test_delete_answers_immediately_without_aws_calls(lambda_module, monkeypatch):
    calls = install_regions(lambda_module, monkeypatch, {"us-east-1": [INSTANCE]})
    request = event("Delete")
    request["PhysicalResourceId"] = "symbol-identity-center-discovery"
    lambda_module.handler(request, FakeContext())
    assert calls == []
    assert lambda_module.sent == [{
        "Status": "SUCCESS", "Reason": "See the functions CloudWatch Logs",
        "PhysicalResourceId": "symbol-identity-center-discovery",
        "StackId": request["StackId"], "RequestId": "r-1",
        "LogicalResourceId": "IdentityCenterDiscovery", "NoEcho": False, "Data": {}}]


def test_unexpected_error_still_succeeds(lambda_module, monkeypatch):
    class Broken:
        def get_available_regions(self, *a, **k):
            raise RuntimeError("endpoints data missing")

    monkeypatch.setattr(lambda_module.boto3, "session", types.SimpleNamespace(Session=Broken))
    lambda_module.handler(event("Update"), FakeContext())
    response = lambda_module.sent[0]
    assert response["Status"] == "SUCCESS"
    assert "discovery failed (RuntimeError)" in response["Data"]["Problem"]


def test_deadline_is_respected(lambda_module, monkeypatch):
    import threading

    gate = threading.Event()
    calls = install_regions(lambda_module, monkeypatch, {"us-east-1": []})

    def slow_client(service, region_name=None, config=None):
        class Client:
            def list_instances(self, **kwargs):
                # Well past the 5 s minimum budget: the handler must answer at the
                # deadline, not when this call happens to return (equal waits raced).
                gate.wait(30)
                return {"Instances": []}
        return Client()

    monkeypatch.setattr(lambda_module.boto3, "client", slow_client)
    # 20 s reserved for the response: 21 s remaining leaves the 5 s minimum budget.
    import time
    started = time.monotonic()
    lambda_module.handler(event(), FakeContext(millis=21_000))
    gate.set()
    assert time.monotonic() - started < 7
    assert "No answer from us-east-1" in lambda_module.sent[0]["Data"]["Problem"]
    assert calls == []


def test_uses_real_botocore_region_list(lambda_module):
    regions = lambda_module.boto3.session.Session().get_available_regions("sso-admin")
    assert "us-east-1" in regions and "eu-west-1" in regions


def test_source_compiles_under_python_313_syntax(stack):
    source = stack["Resources"]["IdentityCenterDiscoveryFunction"]["Properties"]["Code"]["ZipFile"]
    compile(source, "index.py", "exec")
    assert sys.version_info >= (3, 9)
