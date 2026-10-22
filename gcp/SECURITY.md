# Security model (GCP)

## Trust boundaries

```
Your Google Cloud project / folder / org                    Symbol
-----------------------------------------                   ------
Cloud Shell, signed in as YOU:
git clone --branch gcp-vX.Y.Z (commit pinned)
symbol-setup.sh -> terraform plan -> you approve
-> grants / topics / sink / view
-> service accounts symbol-finops, symbol-observability
   + one Google-generated key each
connection code (SECRET: carries the two key files)
          -------------- you paste it into Symbol ---------->  keys -> Vault (never the database)
                                                               identifiers -> setup record
          <------------- Symbol reads, as those two accounts   only what was granted here
```

- **Public template.** Everything that runs is in this directory: review it, and review
  the plan before typing `y`. The script never runs `eval`, validates every argument
  against a strict pattern, and passes values to Terraform through a JSON variables file
  built only from validated values.
- **One secret crosses the boundary, once, on purpose: the key of each identity.** It
  travels in the connection code, which the script prints once and never writes to a
  file. Symbol accepts a code only for the Symbol organisation and the single-use setup
  session it was made for (24 hours); it moves the keys to its Vault before it records
  anything, keeps only the identifiers (project, e-mails, key ids), and never logs or
  returns a code. Treat the code like the key file it contains: paste it into Symbol's
  setup screen only, then clear the terminal.
- **What Symbol checks in a code.** Each key file must be a service-account key of
  `symbol-finops@<project>` / `symbol-observability@<project>` for the code's project,
  under the key id the code announces, with Google's token endpoint
  (`https://oauth2.googleapis.com/token`): a code pointing a key at another endpoint or
  another account is refused. Symbol then authenticates with the key before it stores
  anything.
- **No standing admin access.** Symbol never receives an owner, editor or IAM-admin
  role. It cannot change IAM, create resources or publish to its own topics.
- **One project, one Symbol organisation.** A project already connected to another
  Symbol organisation is refused.

## Keys

- RSA 2048, created by Google (`TYPE_GOOGLE_CREDENTIALS_FILE`), one per service account.
- **Expiry:** your organisation's `iam.serviceAccountKeyExpiryHours`, or none. Symbol
  shows the expiry it was given.
- **Rotation:** `--rotate finops|observability` (Symbol's *Rotate* gives the command).
  The new key is created first, the old one is deleted at the end of the apply; Symbol
  switches when the new code is pasted.
- **Organisation policy.** If key creation is forbidden, nothing is created unless you
  add `--allow-key-creation-exception`, which creates an exception for **this project
  only** and is removed by `--destroy`.

## Terraform state

- Stored in `gs://<project>-symbol-tfstate` (uniform bucket-level access, public access
  prevention enforced, versioned), in **your** project.
- **It contains the two keys** (`google_service_account_key.private_key`), as any
  Terraform-managed key does, and older versions keep the keys of earlier runs. Restrict
  the bucket to the administrators who run the setup, as you would a key file; after a
  rotation, deleted keys in old state versions are useless (Google has deleted them).
- The saved plan file (which contains the keys once they exist) is deleted after the
  apply, and on any failure.
- The variables file saved next to the state (`symbol.tfvars.json`) holds no secret: the
  same identifiers as the command, plus the rotation ids.
- The script refuses a state bucket of that name that is not in your project
  (bucket-squatting guard).

## Integrity of what runs

- **Template:** Symbol's command clones a tag and checks `git rev-parse HEAD` against the
  commit Symbol's registry pins for that version; a mismatch stops before execution.
  Tags `gcp-vX.Y.Z` are created from a protected branch and never moved.
- **Providers:** pinned exactly (`hashicorp/google` 8.7.0, `hashicorp/http` 3.6.2,
  `hashicorp/time` 0.13.1), and `.terraform.lock.hcl` is committed with their hashes for
  linux, darwin and windows (amd64/arm64): `terraform init` refuses a package whose hash
  differs.
- **Terraform binary** (only when Cloud Shell's is missing or older than 1.5): version
  1.16.6 from `releases.hashicorp.com` over HTTPS; the archive's SHA-256 must equal the
  value **pinned in the script** and the entry in `SHA256SUMS`, and `SHA256SUMS` must carry
  a valid signature by HashiCorp's key `C874011F0AB405110D02105534365D9472D7468F` (checked
  with `gpg`, which Cloud Shell provides; without gpg only the pinned checksum applies).
- **Organisation-policy reads:** HTTPS calls to `orgpolicy.googleapis.com` with your own
  token, read only.

## Least privilege

- Two identities, one per purpose (FinOps vs observability), each revocable on its own.
- Read-only roles, except `pubsub.subscriber` on Symbol's two subscriptions (consume
  only). BigQuery jobs and API quota are billed to your project (`jobUser`,
  `serviceUsageConsumer`). Details and caveats in [PERMISSIONS.md](PERMISSIONS.md).
- The service accounts get no role on themselves: nobody is granted
  `iam.serviceAccountUser` or Token Creator on them.
- Sinks and SCC write through Google-managed service agents granted publisher on one
  topic each.

## Revocation

- **You, at once:** delete the keys (or the service accounts) in **IAM & Admin > Service
  accounts**. Access stops immediately.
- **You, completely:** `symbol-setup.sh --destroy` (README).
- **Symbol:** Disconnect destroys the keys in Symbol's vault (every version and the
  metadata) and returns the destroy command.

## Reporting a vulnerability

Email **security@symbole.ai** with details and, if possible, a reproduction. Please do not
open a public issue. We acknowledge within 2 business days. For a confirmed issue in a
released template we publish a fixed version and mark the affected one deprecated:
Symbol then refuses its codes and prompts customers to update.
