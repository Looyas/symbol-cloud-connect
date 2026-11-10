# Symbol Cloud Connect — Azure (`azure-v1`)

Terraform that connects one Azure subscription to Symbol. The customer's administrator
runs it themselves, in their own Azure Cloud Shell, with their own permissions; Symbol
never touches their tenant.

```bash
# Symbol shows this command on the setup screen. Do not assemble it by hand.
azure/symbol-setup.sh --org <org> --session <uuid> --template azure-vX.Y.Z \
  --modules signin,finops,monitoring,security
```

## Why Terraform here and CloudFormation in `aws/`

This template creates an **Entra ID application per identity**, each with a client secret
Microsoft generates. Applications are **Microsoft Graph** objects, and ARM — what a
"Deploy to Azure" button runs — is the resource plane only: it cannot create one. The
`azuread` Terraform provider can, which is the whole reason this folder is Terraform.

That also settles the launch. A portal deployment would have to return the connection
code as an ARM **deployment output**, and outputs are readable by anyone with read access
on the subscription and persist in its history — so the client secrets would be written
into the customer's ARM history for ever. A Cloud Shell run prints the code to a terminal
and stores it nowhere.

`azurerm` has no FOCUS export resource either
([#29705](https://github.com/hashicorp/terraform-provider-azurerm/issues/29705)), so the
Cost Management export goes through `azapi` against
`Microsoft.CostManagement/exports@2025-03-01`. It stays in state, and `--destroy` still
removes it, which a `null_resource` running `az` would not.

## What it creates

Everything it creates lives in **one resource group** (`symbol-cloud-connect`), which is
what makes `--destroy` complete. An export or namespace you point it at instead is never
touched.

| Module | Created | Role granted |
|---|---|---|
| `signin` | **nothing** — Symbol needs the directory id, which it already has | — |
| `finops` | storage account, container, FOCUS 1.0 export | `Storage Blob Data Reader` on the **storage account**, `Cost Management Reader` on the subscription |
| `monitoring` | Event Hubs namespace (Standard), hub, consumer group `symbol-monitoring`, diagnostic setting `symbol-activity-log` | `Azure Event Hubs Data Receiver` on the **hub** |
| `security` | nothing | `Reader`, `Security Reader`, `Monitoring Reader` on the subscription |

Plus, for any data module: **`Symbol Finops`** and **`Symbol Observability`** — two
applications in your directory, each with one client secret, owned by you.

### Two applications, not one

`Symbol Finops` reads a blob container and the cost APIs. `Symbol Observability` reads the
subscription, Defender and an Event Hub. A single application would hold the union of both
role sets, so a leak of the ingestion credential would also carry read access to every
resource in the subscription. Symbol stores them in separate vault paths and rotates them
independently.

### Neither application gets a Graph permission

Everything Symbol reads is authorised by **Azure RBAC on the subscription**, never by a
Microsoft Graph permission. So neither application needs admin consent, and neither can
read anything in your directory.

Sign-in is the exception, and it is a different application: members sign in through
**Symbol's own multi-tenant application**, which a Global Administrator must grant admin
consent to once. Symbol shows the consent link after the code is accepted.

### It never enables a paid Defender plan

`Microsoft.Security/pricings` is billed per resource per month. Defender for Cloud is
**read** where you already run it and turned on never — the same judgement `aws/` makes
about GuardDuty and Security Hub. The CIS scan runs without it, on Resource Graph alone.

## Options

| Flag | Default | What it does |
|---|---|---|
| `--subscription <guid>` | the active one | Which subscription to connect |
| `--location <region>` | `westeurope` | Where the resource group and its resources live |
| `--existing-export <account>/<rg>/<container>/<dir>/<name>` | — | Read a FOCUS export you already run; nothing is created for FinOps. **Symbol is then granted `Storage Blob Data Reader` on that whole account**, not just the container — see [SECURITY.md](SECURITY.md) |
| `--existing-eventhub <namespace>/<rg>/<hub>` | — | Use a namespace you already run; **only the consumer group is created** |
| `--secret-months <1-24>` | `12` | How long each client secret is valid |
| `--rotate finops\|observability` | — | Replace one secret; paste the new code straight away |
| `--destroy` | — | Remove everything this template created |
| `--yes` | — | Skip the confirmation prompt |

An Event Hubs namespace has a monthly floor of roughly ten euros, unlike an SQS queue, so
`--existing-eventhub` is a real saving. The **consumer group** is created either way: Event
Hubs keeps one position per group, and two readers sharing one lose each other's place.

## What you need

See [PERMISSIONS.md](PERMISSIONS.md). In short: **Owner** on the subscription (or
Contributor **plus** User Access Administrator, because this creates role assignments), and
permission to register an application in the directory. The script checks the second one
before creating anything and names the role an administrator can grant you
(*Application Developer*) if your directory forbids it.

## Terraform state

In **your** subscription: a private, versioned storage account
(`symboltf<hash>`) in the resource group `symbol-cloud-connect-state`, created by the
script. The state contains the client secrets — see [SECURITY.md](SECURITY.md).

## Revoking

```bash
azure/symbol-setup.sh --destroy --org <org> --subscription <guid>
```

To cut access immediately without waiting for a destroy, delete `Symbol Finops` and
`Symbol Observability` in **Microsoft Entra ID → App registrations**. Disconnect Azure in
Symbol as well, so it stops trying to read the subscription.

## Development

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
shellcheck symbol-setup.sh
pytest tests/
```

`.terraform.lock.hcl` is committed with hashes for linux, darwin and windows: a release of
this template is immutable and must plan the same way on every run.
