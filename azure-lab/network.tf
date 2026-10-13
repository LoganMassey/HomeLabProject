resource "azurerm_resource_group" "lab" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Edge subnet: the only place with a public IP. Holds the tunnel endpoint.
resource "azurerm_subnet" "edge" {
  name                 = "snet-edge"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_edge_cidr]
}

# Workload subnet: no public IPs, no inbound from the internet.
# Anything here is reachable only through the tunnel.
resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_workload_cidr]
}

# ---------------------------------------------------------------------------
# User Defined Route
#
# Azure's default routes know nothing about the on-prem lab. Without this,
# a workload VM replying to 10.0.30.50 would hand the packet to Azure's
# default internet route and it would be dropped.
#
# This sends on-prem-bound traffic to the WireGuard VM, which Azure treats
# as a virtual appliance. The VM also needs IP forwarding enabled at both
# the NIC level (Azure) and the OS level (sysctl) — see wireguard.tf.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "workload" {
  name                = "${var.prefix}-rt-workload"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_route" "to_onprem" {
  name                   = "to-onprem"
  resource_group_name    = azurerm_resource_group.lab.name
  route_table_name       = azurerm_route_table.workload.name
  address_prefix         = var.onprem_cidr
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.wireguard.private_ip_address
}

resource "azurerm_subnet_route_table_association" "workload" {
  subnet_id      = azurerm_subnet.workload.id
  route_table_id = azurerm_route_table.workload.id
}
