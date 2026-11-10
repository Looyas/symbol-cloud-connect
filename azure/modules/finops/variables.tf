variable "symbol_org_id" {
  description = "The Symbol organisation."
  type        = string
}

variable "subscription_id" {
  description = "The subscription the export covers."
  type        = string
}

variable "subscription_scope" {
  description = "The subscription's resource id (/subscriptions/<guid>)."
  type        = string
}

variable "location" {
  description = "Region of the storage account this module creates."
  type        = string
}

variable "tags" {
  description = "Tags applied to everything this module creates."
  type        = map(string)
}

variable "create_export" {
  description = "Create the storage account, container and export; false reuses the customer's own."
  type        = bool
}

variable "resource_group_name" {
  description = "Symbol's resource group when creating, the existing account's when reusing."
  type        = string
}

variable "storage_account_name" {
  description = "The storage account the export writes to."
  type        = string
}

variable "container_name" {
  description = "The container the export writes to."
  type        = string
}

variable "directory" {
  description = "rootFolderPath of the export, without a trailing slash."
  type        = string
}

variable "export_name" {
  description = "The export's name, which is also the folder it writes under the directory."
  type        = string
}

variable "principal_id" {
  description = "Object id of the symbol-finops service principal."
  type        = string
}
