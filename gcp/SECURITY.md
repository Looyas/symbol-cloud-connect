# Security model (GCP)

## Trust boundaries

```
Symbol                                     Your Google Cloud project / folder / org
------                                     -----------------------------------------
per-org service accounts sym-<org>-fin/obs  Cloud Shell, signed in as YOU:
(symbol_principal) or a key pair per        git clone --branch gcp-vX.Y.Z (commit pinned)
session, private key in Vault (key_upload)  symbol-setup.sh -> terraform plan -> you approve
publishes: principal e-mails, public        -> grants / topics / sink / view / (SAs + public keys)
certificates (.crt, session-scoped) ------>
                                            connection code: identifiers only
          <-------------------------------- you paste it into Symbol
impersonates its own principal, or signs
with its own private key ----------------->  accepted only for what was granted here
```

- **Public template.** Everything that runs is in this directory: review it, and review
  the plan before typing `y`. The script never runs `eval`, validates every argument
  against a strict pattern, and passes values to Terraform through a JSON variables file
  built only from validated values.
- **No secret crosses the boundary.** Symbol sends principal e-mails and public X.509
  certificates. The code returns project ids, numbers, subscription names, service
  account e-mails and key ids. A leaked code is useless: it is bound to one Symbol
  organisation and one single-use session that expires after 24 hours, and Symbol
  accepts a principal only if it is **the calling organisation's own** principal
  (`principal_mismatch`), or a key only if it can authenticate with the private key it
  holds for that session.
- **No standing admin access.** Symbol never receives an owner, editor or IAM-admin
  role. It cannot change IAM, create resources or publish to its own topics.
- **Confused deputy.** Symbol's principals are per organisation: org B cannot make
  Symbol read org A's project, because A granted only org A's principal.

## Terraform state

- Stored in `gs://<project>-symbol-tfstate` (uniform bucket-level access, public access
  prevention enforced, versioned), in **your** project. Anyone who can read it sees the
  resource configuration.
- It contains **no secret**: there is no private key (keys are created from a public
  certificate, so `private_key` is empty), no token and no password.
- The variables file saved next to it (`symbol.tfvars.json`) holds the same identifiers
  as the code, so that `--destroy` works without the original command.
- The script refuses a state bucket of that name that is not in your project
  (bucket-squatting guard).

## Integrity of what runs

- **Template:** Symbol's command clones a tag and checks `git rev-parse HEAD` against the
  commit Symbol's registry pins for that version; a mismatch stops before execution.
  Tags `gcp-vX.Y.Z` are created from a protected branch and never moved.
- **Providers:** pinned exactly (`hashicorp/google` 8.7.0, `hashicorp/http` 3.6.2), and
  `.terraform.lock.hcl` is committed with their hashes for linux, darwin and windows
  (amd64/arm64): `terraform init` refuses a package whose hash differs.
- **Terraform binary** (only when Cloud Shell's is missing or older than 1.5): version
  1.16.6 from `releases.hashicorp.com` over HTTPS; the archive's SHA-256 must equal the
  value **pinned in the script** and the entry in `SHA256SUMS`, and `SHA256SUMS` must carry
  a valid signature by HashiCorp's key `C874011F0AB405110D02105534365D9472D7468F` (checked
  with `gpg`, which Cloud Shell provides; without gpg only the pinned checksum applies).
- **Certificates** (key_upload): downloaded over HTTPS from Symbol's session URL; the plan
  stops unless the answer is HTTP 200 with exactly one PEM certificate. They are public
  material: tampering could only make the key unusable by Symbol, never grant access to
  anyone else.

## Least privilege

- Two identities, one per purpose (FinOps vs observability), each revocable on its own.
- Read-only roles, except `pubsub.subscriber` on Symbol's two subscriptions (consume
  only). BigQuery jobs and API quota are billed to your project (`jobUser`,
  `serviceUsageConsumer`). Details and caveats in [PERMISSIONS.md](PERMISSIONS.md).
- Sinks and SCC write through Google-managed service agents granted publisher on one
  topic each.

## Revocation

- **You:** `symbol-setup.sh --destroy` (README). In key_upload mode you can also delete
  the keys or the `symbol-*` service accounts in the console; in symbol_principal mode,
  remove the grants (any `sym-<org>-*` member).
- **Symbol:** Disconnect deletes Symbol's rows and Vault secrets and, in
  symbol_principal mode, **disables** the organisation's principals, which cuts access
  immediately.

## Reporting a vulnerability

Email **security@symbole.ai** with details and, if possible, a reproduction. Please do not
open a public issue. We acknowledge within 2 business days. For a confirmed issue in a
released template we publish a fixed version and mark the affected one deprecated:
Symbol then refuses its codes and prompts customers to update.
