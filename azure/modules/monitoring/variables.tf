variable "subscription_scope" {
  description = "The subscription's resource id (/subscriptions/<guid>) -- the diagnostic setting's target."
  type        = string
}

variable "location" {
  description = "Region of the namespace this module creates."
  type        = string
}

variable "tags" {
  description = "Tags applied to everything this module creates."
  type        = map(string)
}

variable "create_namespace" {
  description = "Create the Event Hubs namespace and hub; false reuses the customer's own."
  type        = bool
}

variable "resource_group_name" {
  description = "Symbol's resource group when creating, the existing namespace's when reusing."
  type        = string
}

variable "namespace_name" {
  description = "The Event Hubs namespace, its name alone."
  type        = string
}

variable "eventhub_name" {
  description = "The hub the Activity Log is streamed to."
  type        = string
}

variable "create_consumer_group" {
  description = "Create Symbol's consumer group. False when it already exists on a reused hub."
  type        = bool
  default     = true
}

variable "consumer_group" {
  description = "Symbol's own reader group. Created whether or not the namespace is."
  type        = string
}

variable "diagnostic_name" {
  description = "Name of the subscription diagnostic setting this module creates."
  type        = string
}

variable "partition_count" {
  description = "Partitions of the hub this module creates."
  type        = number
}

variable "retention_days" {
  description = "Message retention of the hub this module creates, in days."
  type        = number
}

variable "principal_id" {
  description = "Object id of the symbol-observability service principal."
  type        = string
}
