"""cfn-lint (required) and cfn-guard (when the binary is available) on both templates."""
import os
import shutil
import subprocess
import sys

import pytest

import cfn

TEMPLATES = [str(cfn.STACK), str(cfn.FORWARDER)]
GUARD_RULES = cfn.HERE / "guard" / "symbol.guard"


#: cfn-lint's console entry point (cfnlint.runner:main), run with this interpreter.
CFN_LINT = [sys.executable, "-c", "import sys; from cfnlint.runner import main; sys.exit(main())"]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600)


def test_cfn_lint_clean_including_informational_checks():
    pytest.importorskip("cfnlint")
    result = run([*CFN_LINT, "--include-checks", "I", "--", *TEMPLATES])
    assert result.returncode == 0, result.stdout + result.stderr


def test_cfn_lint_forwarder_in_other_regions():
    pytest.importorskip("cfnlint")
    result = run([*CFN_LINT, "--regions", "eu-west-1", "us-west-2",
                  "ap-southeast-1", "sa-east-1", "--", str(cfn.FORWARDER)])
    assert result.returncode == 0, result.stdout + result.stderr


def guard_binary():
    return os.environ.get("CFN_GUARD") or shutil.which("cfn-guard")


@pytest.mark.skipif(not guard_binary(), reason="cfn-guard not installed (set CFN_GUARD or add it to PATH)")
def test_cfn_guard_rules_pass():
    result = run([guard_binary(), "validate", "--rules", str(GUARD_RULES),
                  "--data", TEMPLATES[0], "--data", TEMPLATES[1], "--show-summary", "fail"])
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(not guard_binary(), reason="cfn-guard not installed (set CFN_GUARD or add it to PATH)")
def test_cfn_guard_rules_catch_a_trust_without_external_id(tmp_path):
    broken = cfn.STACK.read_text(encoding="utf-8").replace(
        "                sts:ExternalId: !Ref ExternalId",
        "                aws:PrincipalAccount: !Ref \"AWS::AccountId\"", 1)
    assert broken != cfn.STACK.read_text(encoding="utf-8")
    path = tmp_path / "broken.yaml"
    path.write_text(broken, encoding="utf-8")
    result = run([guard_binary(), "validate", "--rules", str(GUARD_RULES), "--data", str(path),
                  "--show-summary", "fail"])
    assert result.returncode != 0
    assert "symbol_cross_account_trust_requires_external_id" in result.stdout
