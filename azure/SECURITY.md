# Security notes — `azure/`

## The connection code is SECRET

Unlike the OCI and AWS codes, which carry identifiers only, an Azure code carries the
**client secret of both applications**. Treat it as a password:

- it is printed **once**, to the terminal, and written to no file by the script;
- paste it into Symbol and nowhere else — not a ticket, not a chat message, not an email;
- clear the Cloud Shell terminal afterwards;
- Symbol moves both secrets into its vault the moment the code is accepted, keeps only the
  identifiers on the session row, and never puts one in a response, a log line or a
  validation error.

Azure cannot show a client secret again once its blade is closed. If the code is lost
before it is pasted, run the setup again with `--rotate`.

## The Terraform state contains the secrets

This is the honest cost of generating credentials declaratively, and it is stated here
rather than left to be discovered.

`symbol-setup.sh` therefore keeps the state in **your own subscription**:

- resource group `symbol-cloud-connect-state`, storage account `symboltf<hash>`;
- private (`--allow-blob-public-access false`), TLS 1.2 minimum, blob versioning on;
- never in Symbol's cloud, and never on the machine the command was pasted from.

Anyone who can read that storage account can read the client secrets. Restrict it as you
would any other secret store, and prefer `--rotate` over leaving a long-lived secret in a
state file you have stopped watching.

## Secrets expire, and that is deliberate

`--secret-months` defaults to 12 and Azure allows at most 24. Many tenants cap it lower by
policy. Symbol shows the expiry on the connection card; run the setup again with
`--rotate finops` or `--rotate observability` before it passes.

An ordinary re-run — changing an option, adding a module — **keeps the secrets Symbol
already holds**. Only `--rotate` replaces one, and only for the identity it names. A
template that minted a new secret on every apply would cut Symbol's access every time the
customer changed a setting.

## The template verifies itself

The command Symbol shows clones this repository at a **pinned tag** and then checks the
clone is the **exact commit** the registry pins:

```bash
test "$(git -C "$d" rev-parse HEAD)" = "<40-hex>" || { echo "Template integrity check failed"; exit 1; }
```

A tag can be moved; a commit cannot. A tampered tag stops there rather than in your
directory.

Symbol also refuses to build a command containing any value `shlex.quote` would have to
change, so nothing can reach the `bash -c '...'` string unquoted. And the launch command is
only ever shown on the setup page, while signed in to Symbol — it is never emailed.

## Least privilege

- Two applications, not one, so a leak of the ingestion credential does not also carry
  subscription-wide read. See [PERMISSIONS.md](PERMISSIONS.md).
- `Storage Blob Data Reader` is scoped to the **container**, not the storage account.
- `Azure Event Hubs Data Receiver` is scoped to the **hub**, and is receive-only.
- Neither application holds a Microsoft Graph permission, so neither needs admin consent
  and neither can read the directory.
- The storage account this template creates has `shared_access_key_enabled = false`:
  Symbol authenticates with a token, and the account keys are one fewer credential to leak.

## What the template refuses to do

- **Enable a paid Defender plan.** `Microsoft.Security/pricings` has real monthly cost; a
  wizard that turned it on would hand you a bill you did not agree to.
- **Overwrite an existing diagnostic setting.** Ours is named `symbol-activity-log`. A
  subscription allows five; taking someone else's would silently stop their pipeline.
- **Share a consumer group.** `symbol-monitoring` is created even when you reuse your own
  namespace, because two readers on one group lose each other's position.
- **Widen its scope.** Everything is scoped to the one subscription named on the command
  line. There is no management-group assignment anywhere in this template.

## Reporting

Security issues: security@symbole.ai. Please do not open a public issue.
