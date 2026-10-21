import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cfn  # noqa: E402


@pytest.fixture(scope="session")
def stack():
    return cfn.load(cfn.STACK)


@pytest.fixture(scope="session")
def forwarder():
    return cfn.load(cfn.FORWARDER)


#: The values Symbol's quick-create link fills in (contract §4.3).
SYMBOL_PARAMS = {
    "SymbolOrgId": "2",
    "SetupSessionId": "0b8f9a7e-3c2d-4e1f-9a8b-7c6d5e4f3a2b",
    "TemplateVersion": "aws-v1.0.0",
    "SymbolPrincipalArn": "arn:aws:iam::999988887777:role/symbol-cloud-connector",
    "ExternalId": "kq3V9x_Zt0-YbLwPq7RmN2sA8dFgHjK4lE6cU1oI",
    "SymbolEgressCidrs": "196.203.252.10/32,2001:db8::/48",
}


@pytest.fixture
def symbol_params():
    return dict(SYMBOL_PARAMS)
