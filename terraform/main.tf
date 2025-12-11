terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.33.0"
    }
  }

  backend "azurerm" {
    # Backend configuration provided during terraform init via -backend-config flags
    # This allows the state to be shared across workflow runs and manual executions
  }
}

data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}