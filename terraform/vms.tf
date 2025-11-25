resource "azurerm_public_ip" "pip" {
  for_each            = local.virtual_machines
  name                = "${each.value.name}-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  domain_name_label   = each.value.name
  tags                = local.common_tags
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

resource "azurerm_network_interface" "nic" {
  for_each            = local.virtual_machines
  name                = "${each.value.name}-nic"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = local.common_tags
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_assoc" {
  for_each                  = azurerm_network_interface.nic
  network_interface_id      = each.value.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each              = local.virtual_machines
  name                  = each.value.name
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = data.azurerm_resource_group.rg.location
  size                  = "Standard_DS1_v2"
  admin_username        = var.ssh_user
  network_interface_ids = [azurerm_network_interface.nic[each.key].id]
  tags                  = local.common_tags

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }

  admin_ssh_key {
    username   = var.ssh_user
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "suse"
    offer     = each.value.image_offer
    sku       = "gen2"
    version   = "latest"
  }



  secure_boot_enabled = true
  vtpm_enabled        = true



}
