# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: GPL-3.0-or-later

provider "azurerm" {
  features {
  }
  use_msi     = false
  use_cli     = true
  use_oidc    = false
  environment = "public"
}
