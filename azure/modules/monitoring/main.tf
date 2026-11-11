###############################################################################
# Monitoring: the Activity Log, streamed to an Event Hub Symbol reads.
#
# TWO CREDENTIALS, GOING OPPOSITE WAYS
# ------------------------------------
# Azure Monitor WRITES into the hub with a SAS rule on the namespace
# (`RootManageSharedAccessKey`, which every namespace is created with). Symbol READS
# from it with an Entra token as symbol-observability, through the "Azure Event Hubs
# Data Receiver" role below. They are unrelated: no key of the customer's reaches
# Symbol, and Symbol's identity cannot write.
#
# SYMBOL ALWAYS READS THROUGH ITS OWN CONSUMER GROUP
# -------------------------------------------------
# Event Hubs gives each group its own cursor; two readers sharing `$Default` compete for
# the same partitions, and Symbol's checkpoint store (monitoring-service:
# EventHubOffsetStore) assumes it owns its group's offsets outright. The group is
# `symbol-monitoring`, created here UNLESS IT ALREADY EXISTS: the manual guide creates
# the very same one, and symbol-setup.sh looks before planning.
#
# A REUSED HUB GETS NO DIAGNOSTIC SETTING FROM US
# ----------------------------------------------
# A hub the customer points us at is already fed -- that is what pointing us at it
# means -- and Azure refuses a second setting sending the same category to the same
# destination. connections-service checks the routing when the code is pasted and
# reports in words when nothing writes there.
###############################################################################

locals {
  namespace_id = var.create_namespace ? azurerm_eventhub_namespace.symbol[0].id : data.azurerm_eventhub_namespace.existing[0].id

  # The hub, addressed by id. For a namespace we did not create, the id is built from
  # the namespace's rather than read back: a data source would be one more permission
  # the admin needs for no extra certainty.
  eventhub_id = var.create_namespace ? azurerm_eventhub.activity[0].id : "${local.namespace_id}/eventhubs/${var.eventhub_name}"

  # Azure Monitor's own writer. Present on every namespace from creation.
  send_rule_id = "${local.namespace_id}/authorizationRules/RootManageSharedAccessKey"
}

data "azurerm_eventhub_namespace" "existing" {
  count = var.create_namespace ? 0 : 1

  name                = var.namespace_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_eventhub_namespace" "symbol" {
  count = var.create_namespace ? 1 : 0

  name                = var.namespace_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Standard, not Basic: Basic allows exactly one consumer group ($Default), which is
  # the one arrangement this module refuses to use.
  sku      = "Standard"
  capacity = 1

  public_network_access_enabled = true
  minimum_tls_version           = "1.2"

  # Symbol reads with an Entra token; local SAS keys stay for Azure Monitor's own
  # writer, which has no other way in.
  local_authentication_enabled = true

  tags = var.tags
}

resource "azurerm_eventhub" "activity" {
  count = var.create_namespace ? 1 : 0

  name         = var.eventhub_name
  namespace_id = azurerm_eventhub_namespace.symbol[0].id

  partition_count   = var.partition_count
  message_retention = var.retention_days

  lifecycle {
    # A NAMESPACE COMES BACK EMPTY WHEN IT IS REPLACED, AND THIS HUB MUST GO WITH IT.
    #
    # Changing the region replaces the namespace. The provider still plans this hub as
    # an in-place UPDATE -- namespace_id is only "known after apply", so nothing marks
    # it as forcing replacement -- and that update then fails on any property Azure
    # refuses to shrink: `partition_count cannot be decreased`. Even when it does not
    # fail, Terraform is left believing in a hub that no longer exists, inside a
    # namespace that was rebuilt without it.
    #
    # Tying the hub's life to the namespace's is the whole fix: replaced together,
    # recreated together, with the partition count this template asks for.
    replace_triggered_by = [azurerm_eventhub_namespace.symbol[0]]
  }
}

resource "azurerm_eventhub_consumer_group" "symbol" {
  # Not created when it is already there: Terraform cannot create what exists without
  # an import, and a customer who connected through the manual guide has this exact
  # group already. azure-v1.0.4 failed there.
  count = var.create_consumer_group ? 1 : 0

  name                = var.consumer_group
  namespace_name      = var.namespace_name
  eventhub_name       = var.eventhub_name
  resource_group_name = var.resource_group_name

  user_metadata = "Symbol monitoring-service. Do not use for another reader."

  depends_on = [azurerm_eventhub.activity]
}

# `count` renamed the address; this keeps a group already in state instead of
# destroying and recreating it -- which would reset Symbol's position in the hub.
moved {
  from = azurerm_eventhub_consumer_group.symbol
  to   = azurerm_eventhub_consumer_group.symbol[0]
}

###############################################################################
# The Activity Log, routed into the hub.
#
# Named `symbol-activity-log` so it never collides with a diagnostic setting the
# customer already has -- a subscription allows five, and overwriting one would
# silently stop somebody else's pipeline.
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  # Only with a namespace this template creates. See the header: a reused hub is already
  # fed, and a second setting on the same categories and destination is refused.
  count = var.create_namespace ? 1 : 0

  name               = var.diagnostic_name
  target_resource_id = var.subscription_scope

  eventhub_name                  = var.eventhub_name
  eventhub_authorization_rule_id = local.send_rule_id

  # The three categories monitoring-service's parser understands (app/pipeline/parse.py):
  # control-plane writes, Defender alerts and policy evaluations. Streaming categories
  # nothing reads would cost the customer per ingested event for messages Symbol
  # refuses.
  enabled_log {
    category = "Administrative"
  }

  enabled_log {
    category = "Security"
  }

  enabled_log {
    category = "Policy"
  }

  depends_on = [azurerm_eventhub_consumer_group.symbol]
}

moved {
  from = azurerm_monitor_diagnostic_setting.activity_log
  to   = azurerm_monitor_diagnostic_setting.activity_log[0]
}

###############################################################################
# What symbol-observability may do with the hub. One role, receive-only.
###############################################################################

resource "azurerm_role_assignment" "eventhub_receiver" {
  scope                = local.eventhub_id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = var.principal_id
  principal_type       = "ServicePrincipal"

  description = "Symbol monitoring reads the Activity Log events. Receive only."

  depends_on = [azurerm_eventhub.activity]
}
