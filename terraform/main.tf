terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.33.0"
    }
  }
}

data "azurerm_resource_group" "rg" {
  name = var.azure_resource_group
}