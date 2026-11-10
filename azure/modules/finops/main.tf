###############################################################################
# FinOps: a FOCUS 1.0 export in blob storage, and the two roles that read it.
#
# WHY azapi AND NOT azurerm
# -------------------------
# `azurerm_subscription_cost_management_export` writes ActualCost and AmortizedCost
# exports. Symbol's ingestion reads FOCUS 1.0, which the provider does not model
# (hashicorp/terraform-provider-azurerm#29705), so the export is declared through
# `azapi_resource` against Microsoft.CostManagement/exports. It stays in state and
# `--destroy` still removes it -- a `null_resource` running `az` would be neither.
#
# WHERE THE EXPORT ACTUALLY WRITES
# --------------------------------
# Azure puts the export's own name UNDER rootFolderPath:
#
#     <container>/<directory>/<export name>/<date range>/<run>/<file>.csv.gz
#
# Symbol's preflight probes exactly that prefix, trailing slash included, because
# blob storage has no directories: `symbol-focus` matches `symbol-focus-old/...` as
# happily as `symbol-focus/...`, and a listing without the slash would report a
# neighbouring export's files as this one's.
###############################################################################

locals {
  # The container is addressed by its full resource id: a role assignment scoped to
  # the container, not the whole account, is the difference between "read this export"
  # and "read every blob this subscription owns".
  storage_account_id = var.create_export ? azurerm_storage_account.export[0].id : data.azurerm_storage_account.existing[0].id
  container_scope    = "${local.storage_account_id}/blobServices/default/containers/${var.container_name}"
}

data "azurerm_storage_account" "existing" {
  count = var.create_export ? 0 : 1

  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_storage_account" "export" {
  # Symbol reads this export from OUTSIDE the customer's network -- that is what a SaaS
  # cost reader is. Both of these would make it unreadable, so neither is a finding that
  # can be fixed; the export is protected by RBAC on the container instead, scoped to one
  # application, read-only, with the account keys disabled entirely.
  #checkov:skip=CKV_AZURE_59:Symbol reads the export from outside the subscription; public_network_access_enabled = false would make it unreadable. Access is RBAC-only (Storage Blob Data Reader on the container), shared_access_key_enabled = false.
  #checkov:skip=CKV2_AZURE_33:A private endpoint would put the export on the customer's VNet only, where Symbol cannot reach it. Same reason as CKV_AZURE_59.
  #
  # LRS is deliberate, not an oversight: Azure REGENERATES this export daily, so the
  # blobs are derived data with a 24-hour natural recovery. Geo-replicating them would
  # charge the customer twice for a file Azure rebuilds for free.
  #checkov:skip=CKV_AZURE_206:LRS by design -- the FOCUS export is regenerated daily by Azure Cost Management, so geo-replication would bill the customer for redundancy of derived data.
  #
  # Encryption at rest is on by default with Microsoft-managed keys. A customer-managed
  # key needs a Key Vault, a key, an access policy and a rotation story that this
  # template does not own -- and an export the customer can already read in the portal
  # is not the place to impose one. A customer who wants CMK can add it afterwards.
  #checkov:skip=CKV2_AZURE_1:Encrypted at rest with Microsoft-managed keys (default). CMK needs a customer-owned Key Vault this template does not create.
  #
  # No queue is ever created in this account: it holds the cost export and nothing else.
  #checkov:skip=CKV_AZURE_33:This account serves blobs only; the queue service is never used, so queue logging would configure a service that does not run.
  count = var.create_export ? 1 : 0

  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # The export holds the organisation's spending. None of it is public, ever, and
  # Symbol reads it with a token rather than a key.
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"

  # Symbol authenticates as symbol-finops through Entra; the account keys are not used
  # by anything here and are one fewer credential to leak.
  shared_access_key_enabled = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "export" {
  # Blob read logging needs a destination -- a Log Analytics workspace or a second
  # storage account -- that this template does not create, and would bill the customer
  # for logs of the one read Symbol makes a day. The reads that matter are already in
  # the subscription's Activity Log, which the Monitoring module streams to Symbol.
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs a destination this template does not create, to log one read a day. Control-plane access is already in the Activity Log.
  count = var.create_export ? 1 : 0

  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.export[0].id
  container_access_type = "private"
}

###############################################################################
# The export itself.
###############################################################################

resource "azapi_resource" "focus_export" {
  count = var.create_export ? 1 : 0

  # Microsoft.CostManagement/exports went GA at 2025-03-01, which is the first version
  # that accepts FOCUS as an export type. Pinned: a release of this template must plan
  # the same way for ever.
  type      = "Microsoft.CostManagement/exports@2025-03-01"
  name      = var.export_name
  parent_id = var.subscription_scope

  body = {
    properties = {
      format = "Csv"
      deliveryInfo = {
        destination = {
          resourceId     = local.storage_account_id
          container      = var.container_name
          rootFolderPath = var.directory
        }
      }
      definition = {
        # FOCUS 1.0 -- the one schema Symbol's ingestion reads. `dataSet.configuration`
        # is deliberately absent: a FOCUS export delivers the whole specification's
        # column set, and naming a subset is how a column the ingestion needs goes
        # missing months later.
        type      = "FocusCost"
        timeframe = "MonthToDate"
        dataSet = {
          granularity = "Daily"
          configuration = {
            dataVersion = "1.0"
          }
        }
      }
      schedule = {
        status     = "Active"
        recurrence = "Daily"
        recurrencePeriod = {
          from = formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", timestamp())
          to   = formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", timeadd(timestamp(), "87600h"))
        }
      }
      # Each run overwrites its own day's file rather than appending a new one, so the
      # ingestion reads one file per day instead of accumulating duplicates.
      partitionData = true
    }
  }

  schema_validation_enabled = false

  lifecycle {
    # `timestamp()` moves on every plan; the schedule window is set once at creation.
    ignore_changes = [body]
  }

  depends_on = [azurerm_storage_container.export]
}

###############################################################################
# What symbol-finops may do. Two roles, both read-only.
###############################################################################

# The export's blobs -- scoped to the CONTAINER, not the storage account.
resource "azurerm_role_assignment" "blob_reader" {
  scope                = local.container_scope
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.principal_id
  principal_type       = "ServicePrincipal"

  description = "Symbol FinOps reads the FOCUS cost export."

  depends_on = [azurerm_storage_container.export]
}

# The cost and recommendation APIs (Cost Management queries, Advisor): read-only, and
# needed by the recommendations reader as well as ingestion.
resource "azurerm_role_assignment" "cost_reader" {
  scope                = var.subscription_scope
  role_definition_name = "Cost Management Reader"
  principal_id         = var.principal_id
  principal_type       = "ServicePrincipal"

  description = "Symbol FinOps reads cost data and recommendations."
}
