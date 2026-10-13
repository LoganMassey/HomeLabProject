output "wireguard_public_ip" {
  description = "Tunnel endpoint. This is the Endpoint value in the EdgeRouter peer config."
  value       = azurerm_public_ip.wireguard.ip_address
}

output "wireguard_private_ip" {
  description = "Private IP of the tunnel endpoint, used as the UDR next hop."
  value       = azurerm_network_interface.wireguard.private_ip_address
}

output "workload_private_ip" {
  description = "Workload VM. Reachable only across the tunnel — ping this to prove routing works."
  value       = azurerm_network_interface.workload.private_ip_address
}

output "ssh_to_wireguard" {
  description = "Ready-made SSH command."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.wireguard.ip_address}"
}

output "log_analytics_workspace_id" {
  description = "Workspace id — needed when onboarding Microsoft Sentinel."
  value       = azurerm_log_analytics_workspace.lab.workspace_id
}

output "vnet_cidr_deployed" {
  description = "Confirm this does not overlap the on-prem 10.0.0.0/16."
  value       = azurerm_virtual_network.lab.address_space
}
