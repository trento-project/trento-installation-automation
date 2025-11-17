data "local_file" "machines_csv_file" {
  filename = "../.machines.conf.csv"
}

locals {
  machines_list = csvdecode(tostring(data.local_file.machines_csv_file.content))

  source_virtual_machines = {
    for vm in local.machines_list :
    "${vm.prefix}${vm.slesVersion}sp${vm.spVersion}-${vm.suffix}" => vm
  }

  virtual_machines = {
    for key, vm in local.source_virtual_machines :
    key => {
      name = "${vm.prefix}${vm.slesVersion}sp${vm.spVersion}${vm.suffix}"

      image_offer = tonumber(vm.slesVersion) >= 16 ? "sles-sap-${vm.slesVersion}-${vm.spVersion}-byos-x86-64" : "sles-sap-${vm.slesVersion}-sp${vm.spVersion}-byos"

      sp_version = vm.spVersion
    }
  }

  common_tags = {
    Owner = var.azure_owner_tag
  }


}
