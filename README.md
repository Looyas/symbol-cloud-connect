# Symbol Cloud Connect for OCI

Public Terraform stack for **OCI Resource Manager** that connects an OCI tenancy to Symbol.
You run it in your own OCI console, with your own credentials. Symbol never gets an
administrator credential. Only public material goes in: Symbol's public keys,
certificates and egress IPs. Only identifiers come out: the **connection code**.

| Module | What the stack creates | Used by Symbol for |
|---|---|---|
| `signin` | Confidential app **Symbol Integration** (no admin role) and Identity Propagation Trust **Symbol-Trust** in the identity domain you choose | Users sign in to Symbol with their OCI account and act with **their own** OCI permissions |
| `finops` | Service user and group `symbol-finops`, an API key (public half from Symbol), policy `symbol-finops-policy` | Cost reports, inventory, Cloud Advisor recommendations |
| `monitoring` | Stream pool, stream and Events rule `symbol-monitoring-*`, policy `symbol-events-policy`, Cloud Guard **only if it is not already in use** | Cloud Guard problems in Symbol |
| `security` | Read/inspect statements for `symbol-observability` | CIS security scan |

Service identities (`symbol-finops`, `symbol-observability`) are **API-key-only users** in your
Default identity domain: no password and no console access. Each gets a primary email
`<user>@<service_user_email_domain>` (default `noreply.symbole.ai`; no mail is sent). They work **only from Symbol's
egress IPs**, through the network source `symbol`. Every statement is listed in
[PERMISSIONS.md](PERMISSIONS.md). The trust model is in [SECURITY.md](SECURITY.md).

## How you get here

1. In Symbol, go to **Administration > Cloud configuration > OCI > Configure**. Pick the modules and choose **Automatic**.
2. Symbol creates a setup session. It generates one RSA key pair per service identity and keeps the private keys. It then shows **Open in OCI Resource Manager**. The link has this form:
   ```
   https://cloud.oracle.com/resourcemanager/stacks/create
     ?zipUrl=<this release's zip on GitHub>
     &zipUrlVariables={"symbol_org_id":"…","setup_session_id":"…","finops_public_key_url":"…",…}
   ```
   It contains only public values. The public keys are served at a session URL that expires after 24 hours.
3. Sign in to OCI **in your home region**, as a user who can manage IAM policies and your identity domain.

## Running the stack

1. **Stack information.** Check that the zip comes from `github.com/Looyas/symbol-cloud-connect/releases/download/oci-vX.Y.Z/…`. You can compare its SHA-256 with the one Symbol and the GitHub release show.
2. **Configure variables.**
   - *Symbol (pre-filled - do not change):* the link fills these in. If you change them, Symbol rejects the connection code.
   - *Your tenancy:* the identity domain your users sign in with (for sign-in), the compartment for the monitoring stream (empty means root), an optional compartment to limit security scanning, and the Cloud Guard behaviour.
3. **Plan.** Review it before applying (see below).
4. **Apply.** The job runs with your permissions and is recorded in OCI Audit. It takes about 2 to 5 minutes.
5. **Outputs** (*Application information* tab): copy **Symbol connection code** (`SYMBOL-OCI-1.…`) and paste it into Symbol.
   - With `signin_auth_method = CLIENT_SECRET` (the v1 default), also copy the application's client secret and paste it into Symbol's masked field. Find it under **Identity & Security > Domains > *your domain* > Integrated applications > Symbol Integration > OAuth configuration**. By design it is never in an output.
6. Symbol checks every module from its own IPs and shows a green checklist. IAM propagation can take a few minutes.

### Reviewing the Plan

The Plan lists every resource and attribute. Check these:

- `oci_identity_policy.*`: the `statements` must match [PERMISSIONS.md](PERMISSIONS.md). Every `allow` granted to a Symbol group ends with `where request.networkSource.name='symbol'`.
- `oci_identity_network_source.symbol`: `public_source_list` must equal the egress IPs Symbol publishes.
- `oci_identity_domains_app.symbol`: `redirect_uris` has exactly one Symbol URL. There is no app role or grant.
- `oci_identity_domains_identity_propagation_trust.symbol`: `allow_impersonation = false`.
- `oci_cloud_guard_*`: these appear **only** if Cloud Guard is disabled, or enabled with no target at all. An existing Cloud Guard setup is never modified.

To get approval first, run **Plan** and export the job logs, or download the zip and run `terraform plan` locally (see `oci/terraform.tfvars.example`).

## Revoking access (Destroy)

Two steps, because OCI refuses to delete an **active** application:

1. **Resource Manager > Stacks > this stack > Edit > Edit stack**, tick **Prepare removal**,
   save, then **Apply**. The Symbol Integration app and the Symbol-Trust trust are
   deactivated: sign-in through Symbol stops immediately.
2. **Destroy**. It removes everything the stack created: users, keys, groups, policies, the
   network source, the app, the trust, the stream and the rule.

Without step 1, Destroy fails on the app with `400 ... DeleteApp` (the app is still active).
If that already happened: deactivate the app in the console (Integrated applications >
Symbol Integration > Deactivate), then run Destroy again.

Symbol's daily health check then marks the integration **Revoked**. Notes:

- Destroy leaves Cloud Guard **enabled**, even when this stack enabled it. Only the
  `symbol-cloud-guard-root` target is removed. Disable Cloud Guard yourself if you want.
- Destroy re-reads the public-key URLs. This is harmless after the session has expired (404),
  but if Symbol is unreachable the read fails. In that case, edit the stack variables and
  paste any PEM public key into `finops_public_key_pem` / `observability_public_key_pem`
  (and a certificate into `symbol_ipt_certificate_pem`). Then run Destroy again.

In Symbol, **Disconnect** (`DELETE /oci/integration?purge=true`) deletes Symbol's side.
Run Destroy as well.

## Updating

When Symbol shows *Update available*, it creates a new session and link. In Resource
Manager, go to **Edit stack**, upload the new zip and variables, run **Plan** (it shows only
the differences), then **Apply**. Releases are immutable and listed in
[CHANGELOG.md](CHANGELOG.md).

## Repository layout

```
oci/                     the stack (zipped as-is, root files at the zip root)
  versions.tf providers.tf variables.tf locals.tf main.tf outputs.tf schema.yaml
  modules/{network,signin,finops,observability,monitoring,service-identity}
  tests/stack.tftest.hcl offline tests with mocked providers (not shipped)
scripts/package.sh       builds dist/symbol-oci-stack-vX.Y.Z.zip and its .sha256
.github/workflows/       validate (fmt, validate, test, tflint, checkov) and release (on tag oci-v*)
```

Local checks:

```bash
cd oci
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test                       # Terraform >= 1.7, mocked providers, no OCI account
tflint --config=../.tflint.hcl --recursive
```

Requirements: Terraform 1.5.x (what Resource Manager runs), provider `oracle/oci` 9.3.0,
and `hashicorp/http` 3.6.2. Resource Manager fetches both providers from the Terraform Registry.
