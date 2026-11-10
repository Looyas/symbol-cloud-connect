variable "symbol_org_id" {
  description = "The Symbol organisation, used in the application display names."
  type        = string
}

variable "needs_finops" {
  description = "Create the symbol-finops application."
  type        = bool
}

variable "needs_observability" {
  description = "Create the symbol-observability application."
  type        = bool
}

variable "secret_valid_months" {
  description = "Validity of each client secret, in months."
  type        = number
}

variable "secret_rotation_ids" {
  description = "Per identity, the value that triggers a new secret when it changes."
  type        = map(string)
  default     = {}
}

variable "owner_object_id" {
  description = <<-EOT
    The admin running the setup, made owner of each application so they can manage and
    delete them afterwards without Application Administrator in the directory. Without
    an owner, an application created by a non-privileged user is unmanageable by them.
  EOT
  type        = string
}
