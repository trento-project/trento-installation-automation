# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: Apache-2.0

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

variable "ssh_private_key_content" {
  type        = string
  description = "SSH private key for provisioner connections"
  sensitive   = true
}

variable "environment_suffix" {
  type        = string
  description = "Suffix appended to VM and network resource names to keep concurrent environments apart"
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.environment_suffix)) && !endswith(var.environment_suffix, "-")
    error_message = "The environment_suffix must be lowercase alphanumeric or hyphens, and must not end with a hyphen."
  }
}
