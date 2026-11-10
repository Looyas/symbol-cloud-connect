variable "subscription_scope" {
  description = "The subscription's resource id (/subscriptions/<guid>)."
  type        = string
}

variable "principal_id" {
  description = "Object id of the symbol-observability service principal."
  type        = string
}
