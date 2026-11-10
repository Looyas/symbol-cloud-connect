# What the administrator needs, and what Symbol gets

Two different questions. The first is about the person running the setup; the second is
about the identities it leaves behind.

## 1. What YOU need to run the setup

### On the subscription

**Owner**, or **Contributor + User Access Administrator**.

Contributor alone is not enough: every module ends in a role assignment
(`Microsoft.Authorization/roleAssignments/write`), and Contributor explicitly excludes it.
That is deliberate on Azure's part — being able to create resources is not the same as
being able to grant access to them.

### In the directory

Permission to **register an application**. By default Entra allows any user to
(`authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps = true`), but many
organisations turn it off.

`symbol-setup.sh` reads that policy **before creating anything** and, if it is off, checks
whether you hold a directory role that overrides it (*Application Developer*, *Application
Administrator*, *Cloud Application Administrator* or *Global Administrator*). If neither,
it stops and prints the fix rather than failing halfway through an apply with a Graph
error that does not say what to do.

### For the `signin` module only

A **Global Administrator** must grant admin consent to Symbol's own sign-in application —
once, from the link Symbol shows after the code is accepted. This is not something the
template can do, and not something you need before running it: the setup completes, and
the sign-in check stays red until the consent is granted.

## 2. What Symbol gets

Two applications in **your** directory, which **you own**. Both are read-only, and neither
holds a single Microsoft Graph permission — so neither can read anything in the directory
itself.

### `Symbol Finops`

| Role | Scope | Why |
|---|---|---|
| `Storage Blob Data Reader` | the export's **container** | Reads the FOCUS 1.0 export (cost ingestion) |
| `Cost Management Reader` | the subscription | Cost queries and Advisor recommendations |

The blob role is scoped to the container, not the storage account: the difference between
"read this export" and "read every blob this subscription owns".

### `Symbol Observability`

| Role | Scope | Why |
|---|---|---|
| `Reader` | the subscription | Resource configuration through Resource Graph (CIS scanning) |
| `Security Reader` | the subscription | Microsoft Defender for Cloud findings, where you run it |
| `Monitoring Reader` | the subscription | Diagnostic settings and metric definitions, which several posture checks inspect |
| `Azure Event Hubs Data Receiver` | the **hub** | Receives Activity Log events. Receive only — it cannot write to the hub or manage it |

All four are built-in Azure roles. None of them can change anything.

## 3. What writes INTO the Event Hub

Azure Monitor, using the namespace's own `RootManageSharedAccessKey` SAS rule. That
credential never leaves your subscription and has nothing to do with Symbol: Symbol reads
with an Entra token as `Symbol Observability`, and the two travel in opposite directions.

## 4. Resource providers

The script registers these if they are not already, which needs Contributor or Owner:

- `Microsoft.CostManagement`
- `Microsoft.EventHub`
- `Microsoft.Insights`
- `Microsoft.Storage`

Registering one that is already registered changes nothing.

## 5. What is NEVER asked for

- **No Graph application permission**, on either application.
- **No write role**, anywhere.
- **No Defender plan is enabled.** `Microsoft.Security/pricings` is billed per resource per
  month; Defender is read where you already run it and turned on never.
- **No management group scope.** Everything is scoped to the one subscription you named.
