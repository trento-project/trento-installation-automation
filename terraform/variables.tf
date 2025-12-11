variable "azure_resource_group" {
  description = "Azure resource group"
  type        = string
}

variable "ssh_public_key_content" {
  type        = string
  description = "SSH public key for VM access"
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHZ/JWVNyc2lzgJZsjab8abaBjqobCYq21k1HQuqnoLD dummy@destroy"
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
