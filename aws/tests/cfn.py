"""CloudFormation helpers for the offline tests: a tag-aware YAML loader and a small
evaluator of the intrinsic functions the templates use.

The evaluator is deliberately strict. It refuses what CloudFormation would refuse at
deploy time and what a lenient evaluator would hide:

* a ``Ref``/``Fn::GetAtt``/``${X}`` to a resource whose Condition is false;
* an unknown parameter, condition, mapping key or intrinsic function;
* a ``Fn::Sub`` variable that is neither a parameter, a pseudo parameter, a resource nor
  a local variable.
"""
from __future__ import annotations

import base64
import re
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional

import yaml

HERE = Path(__file__).resolve().parent
AWS_DIR = HERE.parent
STACK = AWS_DIR / "symbol-aws-stack.yaml"
FORWARDER = AWS_DIR / "symbol-aws-regional-forwarder.yaml"


# --------------------------------------------------------------------------- loader
class CfnLoader(yaml.SafeLoader):
    """SafeLoader that turns short-form tags (!Ref, !Sub, ...) into long-form dicts."""


_FN_TAGS = (
    "Base64", "Cidr", "FindInMap", "GetAZs", "If", "ImportValue", "Join", "Select",
    "Split", "Sub", "Equals", "Not", "And", "Or", "Contains", "EachMemberEquals",
    "EachMemberIn", "RefAll", "ValueOf", "ValueOfAll", "ToJsonString", "Length",
)


def _construct(loader: yaml.Loader, node: yaml.Node) -> Any:
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_mapping(node, deep=True)


def _make_fn(name: str) -> Callable:
    def constructor(loader: yaml.Loader, node: yaml.Node) -> Dict[str, Any]:
        return {f"Fn::{name}": _construct(loader, node)}
    return constructor


for _name in _FN_TAGS:
    CfnLoader.add_constructor(f"!{_name}", _make_fn(_name))
CfnLoader.add_constructor("!Ref", lambda l, n: {"Ref": l.construct_scalar(n)})
CfnLoader.add_constructor("!Condition", lambda l, n: {"Condition": l.construct_scalar(n)})


def _getatt(loader: yaml.Loader, node: yaml.Node) -> Dict[str, Any]:
    value = _construct(loader, node)
    if isinstance(value, str):
        resource, _, attribute = value.partition(".")
        value = [resource, attribute]
    return {"Fn::GetAtt": value}


CfnLoader.add_constructor("!GetAtt", _getatt)


def load(path: Path) -> Dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        return yaml.load(handle, Loader=CfnLoader)  # noqa: S506 - SafeLoader subclass


# --------------------------------------------------------------------------- evaluator
class NoValue:
    """AWS::NoValue: removes the list item or mapping key that holds it."""

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "<AWS::NoValue>"


NO_VALUE = NoValue()


class TemplateError(AssertionError):
    """What CloudFormation would reject at validation or deploy time."""


class Evaluator:
    """Resolves a template for one set of parameter values and fake resource values."""

    def __init__(
        self,
        template: Mapping[str, Any],
        parameters: Mapping[str, str],
        *,
        account: str = "111122223333",
        region: str = "us-east-1",
        partition: str = "aws",
        stack_name: str = "Symbol-Cloud-Connect-2",
        stack_uuid: str = "1a2b3c4d-5e6f-7a8b-9c0d-112233445566",
        attributes: Optional[Mapping[str, Mapping[str, str]]] = None,
    ) -> None:
        self.t = template
        self.account = account
        self.region = region
        self.partition = partition
        self.stack_name = stack_name
        self.params = self._parameters(parameters)
        self.pseudo = {
            "AWS::AccountId": account,
            "AWS::Region": region,
            "AWS::Partition": partition,
            "AWS::StackName": stack_name,
            "AWS::StackId": f"arn:{partition}:cloudformation:{region}:{account}:stack/{stack_name}/{stack_uuid}",
            "AWS::URLSuffix": "amazonaws.com",
            "AWS::NoValue": NO_VALUE,
        }
        self.attributes = {k: dict(v) for k, v in (attributes or {}).items()}
        self._conditions: Dict[str, bool] = {}

    # -- parameters / conditions -------------------------------------------------------
    def _parameters(self, given: Mapping[str, str]) -> Dict[str, str]:
        declared = self.t.get("Parameters", {})
        unknown = set(given) - set(declared)
        if unknown:
            raise TemplateError(f"unknown parameters {sorted(unknown)}")
        values: Dict[str, str] = {}
        for name, spec in declared.items():
            if name in given:
                value = str(given[name])
            elif "Default" in spec:
                value = str(spec["Default"])
            else:
                raise TemplateError(f"parameter {name} has no value and no default")
            pattern = spec.get("AllowedPattern")
            if pattern and not re.fullmatch(pattern, value):
                raise TemplateError(f"parameter {name}={value!r} violates {pattern}")
            if "AllowedValues" in spec and value not in [str(v) for v in spec["AllowedValues"]]:
                raise TemplateError(f"parameter {name}={value!r} not in AllowedValues")
            if spec.get("Type") == "Number":
                number = float(value)
                if "MinValue" in spec and number < float(spec["MinValue"]):
                    raise TemplateError(f"parameter {name} below MinValue")
                if "MaxValue" in spec and number > float(spec["MaxValue"]):
                    raise TemplateError(f"parameter {name} above MaxValue")
            values[name] = value
        return values

    def condition(self, name: str) -> bool:
        if name not in self._conditions:
            if name not in self.t.get("Conditions", {}):
                raise TemplateError(f"unknown condition {name}")
            self._conditions[name] = bool(self._cond(self.t["Conditions"][name]))
        return self._conditions[name]

    def _cond(self, node: Any) -> Any:
        if isinstance(node, dict) and len(node) == 1:
            (key, arg), = node.items()
            if key == "Condition":
                return self.condition(arg)
            if key == "Fn::Equals":
                a, b = (self.resolve(x) for x in arg)
                return str(a) == str(b)
            if key == "Fn::Not":
                return not self._cond(arg[0])
            if key == "Fn::And":
                return all(self._cond(x) for x in arg)
            if key == "Fn::Or":
                return any(self._cond(x) for x in arg)
        return self.resolve(node)

    def resource_enabled(self, logical_id: str) -> bool:
        resource = self.t["Resources"][logical_id]
        return "Condition" not in resource or self.condition(resource["Condition"])

    # -- rules ---------------------------------------------------------------------------
    def failed_rules(self) -> list:
        failed = []
        for name, rule in (self.t.get("Rules") or {}).items():
            if "RuleCondition" in rule and not self._cond(rule["RuleCondition"]):
                continue
            for assertion in rule.get("Assertions", []):
                if not self._cond(assertion["Assert"]):
                    failed.append(name)
        return failed

    # -- resources -----------------------------------------------------------------------
    def _resource(self, logical_id: str) -> Mapping[str, Any]:
        if logical_id not in self.t.get("Resources", {}):
            raise TemplateError(f"unknown resource {logical_id}")
        if not self.resource_enabled(logical_id):
            raise TemplateError(f"reference to {logical_id}, whose Condition is false")
        return self.t["Resources"][logical_id]

    def _prop(self, logical_id: str, name: str) -> Any:
        return self.resolve(self._resource(logical_id).get("Properties", {}).get(name))

    def ref(self, name: str) -> Any:
        if name in self.pseudo:
            return self.pseudo[name]
        if name in self.params:
            return self.params[name]
        resource = self._resource(name)
        override = self.attributes.get(name, {}).get("Ref")
        if override is not None:
            return override
        kind = resource["Type"]
        if kind == "AWS::S3::Bucket":
            return self._prop(name, "BucketName")
        if kind == "AWS::IAM::Role":
            return self._prop(name, "RoleName") or f"{self.stack_name}-{name}-ABCDEF"
        if kind == "AWS::SQS::Queue":
            return f"https://sqs.{self.region}.amazonaws.com/{self.account}/{self._prop(name, 'QueueName')}"
        if kind == "AWS::Events::Rule":
            return self._prop(name, "Name")
        if kind == "AWS::Lambda::Function":
            return self._prop(name, "FunctionName")
        if kind == "AWS::Logs::LogGroup":
            return self._prop(name, "LogGroupName")
        return f"{name}-physical-id"

    def getatt(self, name: str, attribute: str) -> Any:
        resource = self._resource(name)
        override = self.attributes.get(name, {})
        if attribute in override:
            return override[attribute]
        kind = resource["Type"]
        p, r, a = self.partition, self.region, self.account
        if kind == "AWS::IAM::Role" and attribute == "Arn":
            return f"arn:{p}:iam::{a}:role/{self.ref(name)}"
        if kind == "AWS::S3::Bucket" and attribute == "Arn":
            return f"arn:{p}:s3:::{self.ref(name)}"
        if kind == "AWS::SQS::Queue" and attribute == "Arn":
            return f"arn:{p}:sqs:{r}:{a}:{self._prop(name, 'QueueName')}"
        if kind == "AWS::SQS::Queue" and attribute == "QueueName":
            return self._prop(name, "QueueName")
        if kind == "AWS::Events::Rule" and attribute == "Arn":
            return f"arn:{p}:events:{r}:{a}:rule/{self.ref(name)}"
        if kind == "AWS::Lambda::Function" and attribute == "Arn":
            return f"arn:{p}:lambda:{r}:{a}:function:{self.ref(name)}"
        if kind == "AWS::Logs::LogGroup" and attribute == "Arn":
            return f"arn:{p}:logs:{r}:{a}:log-group:{self.ref(name)}:*"
        if kind == "AWS::BCMDataExports::Export" and attribute == "ExportArn":
            return f"arn:{p}:bcm-data-exports:{r}:{a}:export/{name}-0000"
        raise TemplateError(f"no fake value for {name}.{attribute} ({kind})")

    # -- intrinsic functions -------------------------------------------------------------
    def resolve(self, node: Any) -> Any:
        if isinstance(node, list):
            out = [self.resolve(x) for x in node]
            return [x for x in out if x is not NO_VALUE]
        if not isinstance(node, dict):
            return node
        if len(node) == 1:
            (key, arg), = node.items()
            if key == "Ref":
                return self.ref(arg)
            if key == "Condition":
                return self.condition(arg)
            if key.startswith("Fn::"):
                handler = getattr(self, "_fn_" + key[4:].lower(), None)
                if handler is None:
                    raise TemplateError(f"unsupported intrinsic {key}")
                return handler(arg)
        out = {k: self.resolve(v) for k, v in node.items()}
        return {k: v for k, v in out.items() if v is not NO_VALUE}

    def _fn_if(self, arg: list) -> Any:
        name, when_true, when_false = arg
        return self.resolve(when_true if self.condition(name) else when_false)

    def _fn_join(self, arg: list) -> str:
        sep, items = arg
        values = self.resolve(items)
        if not all(isinstance(v, str) for v in values):
            raise TemplateError(f"Fn::Join of non-strings: {values!r}")
        return self.resolve(sep).join(values)

    def _fn_base64(self, arg: Any) -> str:
        value = self.resolve(arg)
        if not isinstance(value, str):
            raise TemplateError("Fn::Base64 of a non-string")
        return base64.b64encode(value.encode("utf-8")).decode("ascii")

    def _fn_select(self, arg: list) -> Any:
        index, items = arg
        return self.resolve(items)[int(self.resolve(index))]

    def _fn_split(self, arg: list) -> list:
        sep, value = arg
        return self.resolve(value).split(self.resolve(sep))

    def _fn_findinmap(self, arg: list) -> Any:
        mapping, top, second = (self.resolve(x) for x in arg)
        try:
            return self.t["Mappings"][mapping][top][second]
        except KeyError as exc:
            raise TemplateError(f"Fn::FindInMap {arg}: {exc}") from exc

    def _fn_getatt(self, arg: list) -> Any:
        name, attribute = arg
        return self.getatt(name, attribute)

    def _fn_equals(self, arg: list) -> bool:
        return self._cond({"Fn::Equals": arg})

    _VAR = re.compile(r"\$\{(!?)([^}]+)\}")

    def _fn_sub(self, arg: Any) -> str:
        if isinstance(arg, str):
            text, local = arg, {}
        else:
            text, variables = arg
            local = {k: self.resolve(v) for k, v in variables.items()}

        def substitute(match: re.Match) -> str:
            literal, name = match.group(1), match.group(2)
            if literal:
                return "${" + name + "}"
            if name in local:
                value = local[name]
            elif "." in name and not name.startswith("AWS::"):
                resource, attribute = name.split(".", 1)
                value = self.getatt(resource, attribute)
            else:
                value = self.ref(name)
            if not isinstance(value, str):
                raise TemplateError(f"${{{name}}} is not a string: {value!r}")
            return value

        return self._VAR.sub(substitute, text)


# --------------------------------------------------------------------------- decoder
CODE_PREFIX = "SYMBOL-AWS-1."
MAX_CODE_CHARS = 8192


def decode_connection_code(code: str) -> Any:
    """The contract §4.5 decoder: strip whitespace; base64 standard or base64url, padded
    or not; at most 8192 characters."""
    import json

    compact = re.sub(r"\s+", "", code or "")
    if len(compact) > MAX_CODE_CHARS:
        raise ValueError("code too long")
    if not compact.startswith(CODE_PREFIX):
        raise ValueError("bad prefix")
    body = compact[len(CODE_PREFIX):].replace("-", "+").replace("_", "/")
    body += "=" * (-len(body) % 4)
    return json.loads(base64.b64decode(body, validate=True).decode("utf-8"))
