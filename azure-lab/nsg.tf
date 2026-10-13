# ---------------------------------------------------------------------------
# NSGs
#
# Azure evaluates rules by priority, lowest number first, and stops at the
# first match. Every NSG has hidden default rules at 65000+ that allow
# intra-VNet traffic and deny everything else inbound.
#
# The explicit deny rules at 4096 below are written so that an auditor reading
# this config can see the deny-by-default posture without knowing Azure's
# implicit behaviour.
#
# They are NOT merely redundant, and this cost a long debugging session. A deny
# at 4096 pre-empts AllowVnetInBound at 65000, so writing one silently removes
# intra-VNet connectivity. Every intra-VNet flow the design depends on must
# then be allowed explicitly at a lower priority — see allow-from-workload
# below. Writing an explicit deny means owning every allow it displaces.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "edge" {
  name                = "${var.prefix}-nsg-edge"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

# WireGuard listener. UDP only — there is no TCP fallback, by design.
resource "azurerm_network_security_rule" "edge_wireguard" {
  name                        = "allow-wireguard-udp"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.edge.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "51820"
  source_address_prefix       = var.admin_source_ip
  destination_address_prefix  = var.subnet_edge_cidr
}

# SSH, restricted to your home address. Not open to the internet.
resource "azurerm_network_security_rule" "edge_ssh" {
  name                        = "allow-ssh-from-admin"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.edge.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.admin_source_ip
  destination_address_prefix  = var.subnet_edge_cidr
}

# Traffic arriving from the on-prem lab through the tunnel.
resource "azurerm_network_security_rule" "edge_from_onprem" {
  name                        = "allow-from-onprem"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.edge.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.onprem_cidr
  destination_address_prefix  = var.subnet_edge_cidr
}

# Return traffic from the workload subnet.
#
# REQUIRED, and not obvious. Azure's implicit AllowVnetInBound at 65000 would
# permit this, but deny-all-inbound at 4096 below fires first and blocks it.
# The workload VM answers every connection and its replies die on the way back
# into the NVA, which looks exactly like a broken tunnel.
#
# Destination is "*", not the edge subnet: these packets are addressed to
# on-prem hosts and are only transiting this NIC.
resource "azurerm_network_security_rule" "edge_from_workload" {
  name                        = "allow-from-workload"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.edge.name
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_workload_cidr
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "edge_deny_all" {
  name                        = "deny-all-inbound"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.edge.name
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "edge" {
  subnet_id                 = azurerm_subnet.edge.id
  network_security_group_id = azurerm_network_security_group.edge.id
}

# ---------------------------------------------------------------------------
# Workload NSG — no internet exposure at all
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "workload" {
  name                = "${var.prefix}-nsg-workload"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

# SSH only from on-prem, only through the tunnel.
resource "azurerm_network_security_rule" "workload_ssh_from_onprem" {
  name                        = "allow-ssh-from-onprem"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.workload.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.onprem_cidr
  destination_address_prefix  = var.subnet_workload_cidr
}

# Allow the edge subnet in, so the tunnel endpoint can reach workloads.
resource "azurerm_network_security_rule" "workload_from_edge" {
  name                        = "allow-from-edge"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.workload.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_edge_cidr
  destination_address_prefix  = var.subnet_workload_cidr
}

resource "azurerm_network_security_rule" "workload_deny_internet_in" {
  name                        = "deny-internet-inbound"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.workload.name
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}
