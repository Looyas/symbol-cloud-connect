# Changelog

Template versions follow `oci-v<MAJOR>.<MINOR>.<PATCH>`. Releases are immutable; each one
publishes `symbol-oci-stack-vX.Y.Z.zip` and its SHA-256. Any change to a policy statement
is listed here under **Permissions**.

## oci-v1.0.4

### Fixed
- **finops / observability**: `symbol-finops` and `symbol-observability` are now
  **API-key-only users** instead of OCI *service users*. A service user gets no API key
  capability: OCI refuses to grant it (`400 Attribute '...capabilities:User:canUseApiKeys'
  is not allowed to be set on a Service User`) and refuses the key itself (`You can not
  create ApiKey for this user`). Up to oci-v1.0.3, `CreateUser` therefore failed for both
  identities in every tenancy, so FinOps, Monitoring and Security could not be set up.
- The users still have **no password and no console access**: no password is set, and the
  capabilities extension turns off every credential type except API keys (console
  password, auth tokens, customer secret keys, DB credentials, OAuth client credentials,
  SMTP). No welcome mail is sent.

### Permissions
- No change.

## oci-v1.0.3

### Fixed
- **finops / observability**: the service users `symbol-finops` and `symbol-observability`
  are created with a **primary email**. Identity domains require one by default
  (*Primary email address required*), and the Apply failed with
  `400-BadErrorResponse ... CreateUser` in every such domain.
  The address is `<user>@<service_user_email_domain>`.

### Added
- Variable **`service_user_email_domain`** (default `noreply.symbole.ai`), shown in the
  *Your tenancy* group. No mail is sent to these addresses (notifications are bypassed);
  an organisation whose policy requires its own domain sets it here. The email is set when
  the users are created only: upgrading a stack applied with an earlier release changes no
  existing user.

### Permissions
- No change.

## oci-v1.0.2

### Changed
- **signin**: an Identity Propagation Trust that already exists in the domain for Symbol's
  issuer -- typically the one created with the earlier manual guide -- is **reused**
  together with the application attached to it. The stack then creates neither the app
  nor the trust (an identity domain accepts one trust per issuer: creating a second one
  failed with `409 conflicted state` after two minutes of retries), and Destroy leaves
  them in place. The stack's own trust (marked in its description) stays managed.
- The plan stops with a clear message when the reused trust is inactive or has no
  application attached, and warns when it trusts another certificate or when its app
  lacks Symbol's redirect URL.
- Upgrading a stack applied with an earlier release keeps its app and trust
  (`moved` blocks).

- **Removal**: new **Prepare removal** option (sign-in). OCI refuses to delete an active
  application, so Destroy failed with `400 ... DeleteApp`. Revoking is now: tick
  *Prepare removal*, Apply (the app and the trust are deactivated, sign-in stops), then
  Destroy.

### Fixed
- A trust with an empty description no longer breaks the plan.

### Permissions
- No change (reading trusts and apps is covered by the identity-domain administrator
  role the admin already needs).

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
