# Changelog (GCP)

Template versions follow `gcp-v<MAJOR>.<MINOR>.<PATCH>` (git tags; Symbol pins tag and
commit). Releases are immutable. Any change to a granted role is listed under
**Permissions**.

## gcp-v1.0.0

First release (CLOUD-SETUP-CONTRACT-V2 §5).

### Added
- `symbol-setup.sh`: Cloud Shell flow (project resolution, Terraform >= 1.5 check with a
  checksum- and signature-verified install of Terraform 1.16.6, bootstrap APIs,
  organisation and effective org-policy detection, automatic identity mode, billing
  export detection, GCS state bucket, plan / confirm / apply, framed connection code),
  `--destroy` (keeps the billing dataset and the state bucket), `--yes` for CI.
- Identity modes `symbol_principal` (grants to Symbol's per-org service accounts) and
  `key_upload` (service accounts `symbol-finops` / `symbol-observability` with Symbol's
  uploaded certificate as their only key).
- **finops**: APIs, dataset `billing_export` when absent, FOCUS view `gcp_focus_v1` over the
  detailed usage cost export (Google's FOCUS v1.0 GA mapping, column names of Symbol's
  reader), grants.
- **monitoring**: topic `symbol-monitoring`, subscription `symbol-monitoring-sub` (ack 60 s,
  retention 7 days, no expiry), audit-log sink `symbol-audit-sink` at project, folder or
  organisation level; optional SCC v2 notification `symbol-scc` with topic `symbol-scc`
  and subscription `symbol-scc-sub`.
- **security**: read-only scanner grants at the chosen scope.
- **finops** scope grants include `roles/storage.bucketViewer` (bucket metadata only) for
  inventory-collector's `storage.buckets.get`.
- Outputs `symbol_connection_code` (`SYMBOL-GCP-1.` + unpadded base64url JSON, §5.7) and
  `symbol_connection_summary`.
- Labels `symbol-managed`, `symbol-org`, `symbol-template` on every labelled resource.
- Committed provider lock file (google 8.7.0, http 3.6.2).

### Permissions
- Initial set, see [PERMISSIONS.md](PERMISSIONS.md).
