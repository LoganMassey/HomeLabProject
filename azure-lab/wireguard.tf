# ---------------------------------------------------------------------------
# WireGuard tunnel endpoint
#
# Azure VPN Gateway speaks IPsec/IKEv2 only — it cannot terminate WireGuard.
# So the tunnel endpoint is a VM acting as a virtual appliance. This is
# cheaper (B1s is free-tier eligible) and makes the routing explicit rather
# than hiding it inside a managed service.
#
# Keys are NOT generated here. Terraform would write the private key into
# state in plaintext, and state is not a secret store. Generate them on the
# VM after boot — see README.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "wireguard" {
  name                = "${var.prefix}-pip-wireguard"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  # Static so the peer config on the EdgeRouter does not break on reboot.
  allocation_method = "Static"
  sku               = "Standard"
  tags              = var.tags
}

resource "azurerm_network_interface" "wireguard" {
  name                = "${var.prefix}-nic-wireguard"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  # Required for this VM to forward packets it is not the destination for.
  # Without it, Azure's fabric silently drops transit traffic and the tunnel
  # appears to work while nothing routes through it. Common gotcha.
  ip_forwarding_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.edge.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.subnet_edge_cidr, 10)
    public_ip_address_id          = azurerm_public_ip.wireguard.id
  }

  tags = var.tags
}

resource "azurerm_linux_virtual_machine" "wireguard" {
  name                = "${var.prefix}-vm-wireguard"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.wireguard.id]

  # Key-based auth only. Password auth is off by default in this resource
  # and is left off deliberately.
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/cloud-init-wireguard.yaml"))

  boot_diagnostics {}

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Workload VM — the thing being protected. No public IP.
# ---------------------------------------------------------------------------

resource "azurerm_network_interface" "workload" {
  name                = "${var.prefix}-nic-workload"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags
}

resource "azurerm_linux_virtual_machine" "workload" {
  name                = "${var.prefix}-vm-workload"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.workload.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}

  tags = var.tags
}
