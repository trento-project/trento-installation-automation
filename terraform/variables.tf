variable "azure_resource_group" {
  description = "Azure resource group"
  type        = string
}

variable "ssh_public_key_content" {
  type        = string
  description = "SSH public key for VM access"
}

variable "ssh_user" {
  type        = string
  description = "SSH user"
  default     = "cloudadmin"
}

variable "azure_owner_tag" {
  type        = string
  description = "azure resources owner tag"
}
