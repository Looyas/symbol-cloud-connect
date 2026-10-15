# Changelog

Template versions follow `oci-v<MAJOR>.<MINOR>.<PATCH>`. Releases are immutable; each one
publishes `symbol-oci-stack-vX.Y.Z.zip` and its SHA-256. Any change to a policy statement
is listed here under **Permissions**.

## oci-v1.0.1

### Fixed
- **signin**: the identity domain is only read when one is selected. With the form's
  domain dropdown left empty, the provider failed with
  `can not marshal ... DomainId ... nil pointer` before the precondition could explain
  the cause; the plan now stops with "Sign-in is enabled: pick the identity domain your
  users sign in with (identity_domain_id)".

### Permissions
- No change.

## oci-v1.0.0

First release.

### Added
- Home-region detection; every IAM and identity-domain write goes through the home-region provider.
- Network source `symbol` (Symbol egress IPs).
- **signin**: confidential app `Symbol Integration` (custom web app template, grants
  `authorization_code`, `client_credentials`, `refresh_token`, single redirect URI, no
  app role), optional trusted-client mode with Symbol's certificate (`CLIENT_ASSERTION`),
  Identity Propagation Trust `Symbol-Trust` (JWT, `sub` -> `userName`,
  `client_id = symbol-broker`, no impersonation).
- **finops**: service user and group `symbol-finops` (Default domain), API key from Symbol,
  `symbol-finops-policy`.
- **monitoring / security**: service user and group `symbol-observability`, API key,
  `symbol-observability-policy` (statements per enabled module).
- **monitoring**: stream pool `symbol-monitoring-pool`, stream `symbol-monitoring-stream`
  (1 partition, 24 h), Events rule `symbol-monitoring-rule`
  (`com.oraclecloud.cloudguard.problemdetected` + extra types), `symbol-events-policy`,
  Cloud Guard enablement only when it is not in use (`create_cloud_guard = auto`).
- Output `symbol_connection_code` (`SYMBOL-OCI-1.` + unpadded base64url JSON, contract v1)
  and `symbol_connection_summary`.
- Tags `symbol-managed`, `symbol-org`, `symbol-template` on every taggable resource.

### Permissions
- Initial set, see [PERMISSIONS.md](PERMISSIONS.md).
