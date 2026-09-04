# SPDX-FileCopyrightText: SUSE LLC
# SPDX-License-Identifier: Apache-2.0

data "local_file" "machines_csv_file" {
  filename = "../.machines.conf.csv"
}

locals {
  machines_list = csvdecode(tostring(data.local_file.machines_csv_file.content))

  source_virtual_machines = {
    for vm in local.machines_list :
    "${vm.prefix}${vm.slesVersion}sp${vm.spVersion}" => vm
  }

  virtual_machines = {
    for key, vm in local.source_virtual_machines :
    key => {
      name = "${vm.prefix}${vm.slesVersion}sp${vm.spVersion}"

      image_offer = tonumber(vm.slesVersion) >= 16 ? "sles-sap-${vm.slesVersion}-${vm.spVersion}-byos-x86-64" : "sles-sap-${vm.slesVersion}-sp${vm.spVersion}-byos"

      sp_version = vm.spVersion
    }
  }

  common_tags = {
    Owner = var.azure_owner_tag
  }

  # Recursive DNS resolver of the Azure platform. It is a static virtual public
  # IP, identical in every region and virtual network, and the address the Azure
  # DHCP server hands out to virtual networks that do not define custom DNS
  # servers, which is the case of the one in networking.tf.
  # https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16
  azure_dns_resolver = "168.63.129.16"
}
