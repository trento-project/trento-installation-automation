provider "azurerm" {
  features {
  }
  use_msi                         = false
  use_cli                         = true
  use_oidc                        = false
  subscription_id                 = "501de51d-cd4c-4a11-a0b6-3b2f0b6f1393"
  environment                     = "public"
}
