variable "azure_resource_group" {
  description = "Azure resource group"
  type        = string
}
variable "azure_vms_location" {
  description = "Region to deploy resources"
  type        = string
}

variable "ssh_public_key_content" {
  type        = string
  description = "Public key content"
}

variable "ssh_user" {
  type        = string
  description = "SSH user"
}

variable "azure_owner_tag" {
  type        = string
  description = "azure resources owner tag"
}
