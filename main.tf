terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"

    }
  }
}

provider "azurerm" {
  features { }
  client_id       = var.ARM_CLIENT_ID
  client_secret   = var.ARM_CLIENT_SECRET
  tenant_id       = var.ARM_TENANT_ID
  subscription_id = var.ARM_SUBSCRIPTION_ID
}

variable "ARM_CLIENT_ID" {
  type = string
  default = ""
}
variable "ARM_CLIENT_SECRET" {
  type = string
  default = ""
}
variable "ARM_TENANT_ID" {
  type = string
  default = ""
}
variable "ARM_SUBSCRIPTION_ID" {
  type = string
  default = ""
}


# create resource group

resource "azurerm_resource_group" "avdrg" {
  name     = "rg_terra_avd"
  location = "Uk South"
  tags = {
    environment = "dev"
  }
}


# networks

resource "azurerm_virtual_network" "avdnet" {
  name                = "vnet_terra_avd"
  location            = azurerm_resource_group.avdrg.location
  resource_group_name = azurerm_resource_group.avdrg.name
  address_space       = ["10.200.0.0/16"]
  #dns_servers         = ["8.8.8.8"]
}

resource "azurerm_subnet" "avdnet" {
  name                 = "avd-snet"
  resource_group_name  = azurerm_resource_group.avdrg.name
  virtual_network_name = azurerm_virtual_network.avdnet.name
  address_prefixes     = ["10.200.1.0/24"]
}

# AVD hostpools

locals {
  avd_location = "UK south"

}

resource "azurerm_virtual_desktop_host_pool" "avdhppool" {
  name                = "avd-terra-pool"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avdrg.name

  type               = "Pooled"
  load_balancer_type = "BreadthFirst"
  friendly_name      = "Terraformed Host Pool"
}

resource "time_rotating" "avd_registration_expiration" {

  rotation_days = 30
}
resource "azurerm_virtual_desktop_host_pool_registration_info" "avdhppool" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.avdhppool.id
  expiration_date = time_rotating.avd_registration_expiration.rotation_rfc3339
}

#Avd workspace

resource "azurerm_virtual_desktop_workspace" "avdws" {
  name                = "avd-terra-workspace"
  friendly_name       = "Terra Workspace"
  description         = "Terraform test ws"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avdrg.name
}

resource "azurerm_virtual_desktop_application_group" "avdappg" {
  name                = "avd-terra-desktop-dag"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avdrg.name

  type         = "Desktop"
  host_pool_id = azurerm_virtual_desktop_host_pool.avdhppool.id
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "avdappgass" {
  workspace_id         = azurerm_virtual_desktop_workspace.avdws.id
  application_group_id = azurerm_virtual_desktop_application_group.avdappg.id
}


# add a user to app group and create entra ID group

data "azurerm_role_definition" "Terraform_AVD_Hostpool_users" {
  name = "Desktop Virtualization User"
}

resource "azuread_group" "avd_users" {
  display_name     = "AVD Users"
  security_enabled = true
}

resource "azurerm_role_assignment" "avd_users_Terraform_AVD_Hostpool_users" {
  scope              = azurerm_virtual_desktop_application_group.avdappg.id
  role_definition_id = data.azurerm_role_definition.Terraform_AVD_Hostpool_users.id
  principal_id       = azuread_group.avd_users.id
}








# deploy a VM

#number

variable "avd_host_pool_size" {
  type        = number
  description = "Number of session hosts to add to the AVD host pool."
}

#nics

resource "azurerm_network_interface" "avdnic" {
  count               = var.avd_host_pool_size
  name                = "avd-nic-${count.index}"
  location            = azurerm_resource_group.avdrg.location
  resource_group_name = azurerm_resource_group.avdrg.name

  ip_configuration {
    name                          = "avd-ipconf"
    subnet_id                     = azurerm_subnet.avdnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

#hosts

resource "random_password" "avd_local_admin" {
  length = 64
}

resource "random_id" "avd" {
  count       = var.avd_host_pool_size
  byte_length = 2
}

resource "azurerm_windows_virtual_machine" "avd" {
  count               = var.avd_host_pool_size
  name                = "avd-vm-${count.index}-${random_id.avd[count.index].hex}"
  location            = azurerm_resource_group.avdrg.location
  resource_group_name = azurerm_resource_group.avdrg.name

  size                  = "Standard_B2s"
  license_type          = "Windows_Client"
  admin_username        = "avd-local-admin"
  admin_password        = random_password.avd_local_admin.result
  network_interface_ids = [azurerm_network_interface.avdnic[count.index].id]

  identity {
    type = "SystemAssigned"
  }


  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-23h2-avd"
    version   = "latest"
  }
}

# add to domain


resource "azurerm_virtual_machine_extension" "aadJoin" {
  #depends_on = [
  #azurerm_windows_virtual_machine.avd_register_session_host,
  #  azurerm_virtual_machine_extension.vm_avd_associate
  #]
  count                      = var.avd_host_pool_size
  name                       = "AADLoginForwindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.avd[count.index].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}
# resource "azurerm_virtual_machine_extension" "addaadjprivate" {
#  depends_on = [
#   azurerm_virtual_machine_extension.AADLoginForWindows
#]
#count                = 2
#name                 = "AADJPRIVATE"
#virtual_machine_id   = azurerm_windows_virtual_machine.avd_sessionhost.*.id[count.index]
# publisher            = "Microsoft.Compute"
# type                 = "CustomScriptExtension"
# type_handler_version = "1.9"

#settings = <<SETTINGS
#{
#   "commandToExecute": "powershell.exe -Command \"${local.powershell_command}\""
#}
#SETTINGS
# }






#  add to pool

variable "avd_register_session_host_modules_url" {
  type        = string
  description = "URL to .zip file containing DSC configuration to register AVD session hosts to AVD host pool."
  default     = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_02-23-2022.zip"
}

resource "azurerm_virtual_machine_extension" "avd_register_session_host" {
  count                = var.avd_host_pool_size
  name                 = "register-session-host-vmext"
  virtual_machine_id   = azurerm_windows_virtual_machine.avd[count.index].id
  publisher            = "Microsoft.Powershell"
  type                 = "DSC"
  type_handler_version = "2.73"

  settings = <<-SETTINGS
    {
      "modulesUrl": "${var.avd_register_session_host_modules_url}",
      "configurationFunction": "Configuration.ps1\\AddSessionHost",
      "properties": {
        "hostPoolName": "${azurerm_virtual_desktop_host_pool.avdhppool.name}",
        "aadJoin": true
      }
    }
    SETTINGS

  protected_settings = <<-PROTECTED_SETTINGS
    {
      "properties": {
        "registrationInfoToken": "${azurerm_virtual_desktop_host_pool_registration_info.avdhppool.token}"
      }
    }
    PROTECTED_SETTINGS

  lifecycle {
    ignore_changes = [settings, protected_settings]
  }

  # depends_on = [azurerm_virtual_machine_extension.avd_aadds_join]
}



# join to entra