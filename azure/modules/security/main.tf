###############################################################################
# Security posture: read-only roles over the subscription.
#
# THIS MODULE NEVER ENABLES A PAID PLAN
# -------------------------------------
# Microsoft Defender for Cloud is read if the customer already runs it, and turned on
# never. `Microsoft.Security/pricings` is billed per resource per month, and a setup
# wizard that silently enabled it would hand the organisation a bill it did not agree
# to. The AWS template makes the same judgement about GuardDuty and Security Hub:
# prerequisites, not creations. Symbol's card lists "Defender for Cloud enabled" as a
# prerequisite, and the scan runs without it on Resource Graph alone.
#
# These three roles are shared by the Monitoring and Security modules: both are read
# by symbol-observability, and either module alone needs the same subscription-wide
# read. They are assigned once, here, whenever that identity exists.
###############################################################################

locals {
  roles = {
    # Resource Graph, resource configuration, the CIS scan's own reads.
    "Reader" = "Symbol reads the subscription's resource configuration (CIS scanning)."
    # Defender for Cloud assessments, secure score and alerts -- read where enabled.
    "Security Reader" = "Symbol reads Microsoft Defender for Cloud findings."
    # Diagnostic settings and metric definitions, which the posture checks inspect.
    "Monitoring Reader" = "Symbol reads diagnostic settings and metric definitions."
  }
}

resource "azurerm_role_assignment" "observability" {
  for_each = local.roles

  scope                = var.subscription_scope
  role_definition_name = each.key
  principal_id         = var.principal_id
  principal_type       = "ServicePrincipal"

  description = each.value
}
