# Security model

## Trust boundaries

```
Symbol                                   Your OCI tenancy
------                                   ----------------
generates key pairs (private keys stay   Resource Manager downloads the public zip from GitHub,
in Symbol's Vault)                       runs it with YOUR permissions (logged in OCI Audit)
publishes: public keys, certificates,    creates identities/policies/stream/app/trust
egress IPs  ---------------------------> (public material only)
                                         outputs the connection code: identifiers only
          <---------------------------- you paste it into Symbol
calls OCI public APIs from its egress
IPs, signed with its private keys  ---->  accepted only from the network source "symbol"
```

- **Public template.** Every line that runs in your tenancy is in this repository. Review it,
  or review the Plan, before you Apply.
- **No secret crosses the boundary.** Symbol sends only public keys, public certificates
  and IP ranges. The stack returns only OCIDs, URLs, key fingerprints and statuses. The
  connection code contains **no secret**. A leaked code is useless: it is bound to one
  Symbol organisation and one single-use session that expires after 24 hours. Its
  fingerprints must also match key pairs that only Symbol holds.
- **No standing admin access.** Symbol never receives a tenancy-admin or
  domain-admin credential. The application has no admin role. Users act with their own
  permissions.

## Least privilege

- Two separate service identities (`symbol-finops`, `symbol-observability`), so each
  module can be revoked on its own.
- Service users have no password and no console access, and API keys are their only
  credential.
- Read/inspect only, except `use stream-pull` on Symbol's own stream. Every statement is
  in [PERMISSIONS.md](PERMISSIONS.md).
- **Network source.** Every `allow` statement granted to a Symbol group requires
  `request.networkSource.name='symbol'`. A stolen key does not work outside Symbol's
  published egress IPs.

## Secrets in Terraform state (read this if you use `CLIENT_SECRET`)

The OCI provider returns the generated **client secret** of the `Symbol Integration`
application as a regular (non-sensitive) attribute. Terraform therefore stores it in the
stack's **state**, which Resource Manager keeps encrypted at rest. Any user who can read the
stack's state (`read orm-stacks` / job state download) can read the secret. It never appears
in an output, and the Plan shows it only as "known after apply".

Mitigations:

- Restrict `manage`/`read` on `orm-stacks` and `orm-jobs` in the compartment that holds the
  stack to tenancy administrators.
- Prefer `CLIENT_ASSERTION` once Symbol enables it. Symbol then authenticates with a
  certificate whose private key is in Symbol's Vault (Transit), and the app's secret is
  never used. You can regenerate the secret in the console at any time; Symbol then needs
  the new value.

The private halves of the API keys are never in the state: only the public keys are.

## Integrity of releases

- Releases are tagged `oci-vX.Y.Z` from a protected branch, with mandatory 2FA, CODEOWNERS
  review and signed commits.
- **Releases are immutable.** The release workflow refuses to overwrite an existing release,
  and a published zip is never replaced.
- Each release publishes `symbol-oci-stack-vX.Y.Z.zip.sha256`. The zip is reproducible
  (`scripts/package.sh`): sorted entries, fixed timestamps.
- Symbol's links pin an exact version, never `latest`. connections-service stores each
  version's SHA-256 and re-downloads the zip daily to compare.
- Providers are pinned to exact versions (`oracle/oci` 9.3.0, `hashicorp/http` 3.6.2).

To verify a download yourself:

```bash
curl -LO https://github.com/Looyas/symbol-cloud-connect/releases/download/oci-v1.0.3/symbol-oci-stack-v1.0.3.zip
curl -LO https://github.com/Looyas/symbol-cloud-connect/releases/download/oci-v1.0.3/symbol-oci-stack-v1.0.3.zip.sha256
sha256sum -c symbol-oci-stack-v1.0.0.zip.sha256
```

## Revocation

- **You:** Resource Manager > Destroy (see README). Symbol's daily health check shows the
  integration as **Revoked**. You can also revoke a single identity by deleting its API key
  or user in the console.
- **Symbol:** Disconnect purges Symbol's copies (rows and Vault secrets, metadata included).

## Reporting a vulnerability

Email **security@symbole.ai** with the details and, if possible, a reproduction. Please do
not open a public issue. We acknowledge within 2 business days. For a confirmed
vulnerability in a released template, we publish a fixed version and mark the affected
version deprecated: Symbol then refuses connection codes from it and prompts customers to
update.
