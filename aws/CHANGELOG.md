# Changelog (AWS)

Template versions follow `aws-v<MAJOR>.<MINOR>.<PATCH>`. Releases are immutable; each one
publishes `aws/aws-vX.Y.Z/symbol-aws-stack.yaml` and
`aws/aws-vX.Y.Z/symbol-aws-regional-forwarder.yaml` on Symbol's S3 bucket, with their
SHA-256. Any change to a permission is listed here under **Permissions**.

## aws-v1.0.0

First release.

### Added
- Main stack `symbol-aws-stack.yaml` (us-east-1, management account, `CAPABILITY_NAMED_IAM`).
  Rules refuse another Region, a stack with no module, an incomplete existing export and a
  start URL without its Region.
- **signin**: custom resource `IdentityCenterDiscovery` (inline Python 3.13 function,
  `sso-admin:ListInstances` across the Regions where Identity Center is offered, short
  timeouts). It never fails the stack and returns a `Problem` text instead. Runs only when
  `IdentityCenterStartUrl` is empty.
- **finops**: role `SymbolFinOps-<org>`; optional bucket `symbol-focus-<account>-<id>`
  (retained on delete) and Data Export `symbol-focus-<org>` (FOCUS 1.0 with AWS columns,
  CSV, gzip, overwrite, prefix `symbol-focus`).
- **monitoring**: role `SymbolObservability-<org>`, queue `symbol-monitoring-<org>` with
  DLQ, EventBridge rule `symbol-monitoring-<org>` (CloudTrail API calls, GuardDuty, Security
  Hub imported findings, Config rules compliance).
- **security**: `SecurityAudit` and `ViewOnlyAccess` on the observability role.
- Regional forwarder `symbol-aws-regional-forwarder.yaml` (one rule and one role per Region).
- Outputs `SymbolConnectionCode` (`SYMBOL-AWS-1.` + base64 JSON, contract v2 §4.5),
  `SymbolConnectionSummary`, `RegionalForwarderTemplateUrl`,
  `RegionalForwarderQuickCreateUrl`, `MonitoringEventBusArn`.
- Tags `symbol-managed`, `symbol-org`, `symbol-template` on every taggable resource.

### Permissions
- Initial set, see [PERMISSIONS.md](PERMISSIONS.md).
