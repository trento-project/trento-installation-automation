provider "azurerm" {
  features {
  }
  use_msi     = false
  use_cli     = true
  use_oidc    = false
  environment = "public"
}
