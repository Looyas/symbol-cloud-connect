output "finops_client_id" {
  description = "Application (client) id of symbol-finops, or null when that identity is not needed."
  value       = var.needs_finops ? azuread_application.this["finops"].client_id : null
}

output "finops_object_id" {
  description = "Service principal object id of symbol-finops -- what a role assignment names."
  value       = var.needs_finops ? azuread_service_principal.this["finops"].object_id : null
}

output "observability_client_id" {
  description = "Application (client) id of symbol-observability, or null."
  value       = var.needs_observability ? azuread_application.this["observability"].client_id : null
}

output "observability_object_id" {
  description = "Service principal object id of symbol-observability -- what a role assignment names."
  value       = var.needs_observability ? azuread_service_principal.this["observability"].object_id : null
}

# SECRET. Read only by outputs.tf, to build the connection code.
output "credentials" {
  description = "Per identity: client_id, object_id, the secret and its expiry. SECRET."
  sensitive   = true
  value = {
    for key, _ in local.identities : key => {
      client_id = azuread_application.this[key].client_id
      object_id = azuread_service_principal.this[key].object_id
      secret    = azuread_application_password.this[key].value
      expires   = azuread_application_password.this[key].end_date
    }
  }
}
