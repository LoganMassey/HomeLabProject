variable "subscription_id" {
  description = "Azure subscription id. Find it with: az account show --query id -o tsv"
  type        = string
}

variable "location" {
  description = "Azure region. Pick one close to you for latency."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Name prefix for all resources."
  type        = string
  default     = "lab"
}

# ---------------------------------------------------------------------------
# Addressing
#
# The on-prem lab uses 10.0.1.0/24, 10.0.20.0/24, 10.0.30.0/24 and
# 10.0.40.0/24 — all inside 10.0.0.0/16. The Azure VNet MUST NOT overlap
# that range or the tunnel cannot route. 10.10.0.0/16 keeps them distinct
# and leaves room to grow on both sides.
# ---------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "Address space for the Azure VNet."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_edge_cidr" {
  description = "Edge subnet — holds the WireGuard tunnel endpoint. Internet-facing."
  type        = string
  default     = "10.10.1.0/24"
}

variable "subnet_workload_cidr" {
  description = "Workload subnet — no public IPs, reachable only via the tunnel."
  type        = string
  default     = "10.10.2.0/24"
}

variable "onprem_cidr" {
  description = "Summary route for the on-prem lab, covering all VLANs."
  type        = string
  default     = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Access control
# ---------------------------------------------------------------------------

variable "admin_source_ip" {
  description = <<-EOT
    Your home public IP in CIDR form, e.g. "203.0.113.45/32".
    SSH and the WireGuard listener are restricted to this.
    Find it with: curl -4 ifconfig.me
    If your ISP address changes, update this and re-apply.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_source_ip))
    error_message = "Must be valid CIDR notation, e.g. 203.0.113.45/32."
  }
}

variable "admin_username" {
  description = "Local admin user on the Linux VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# ---------------------------------------------------------------------------
# Cost controls
# ---------------------------------------------------------------------------

variable "vm_size" {
  description = "B1s is free-tier eligible for 750 hours/month in the first 12 months."
  type        = string
  default     = "Standard_B1s"
}

variable "enable_flow_logs" {
  description = <<-EOT
    VNet Flow Logs require a Network Watcher in the region. Azure usually
    auto-creates one named NetworkWatcher_<region> in the NetworkWatcherRG
    resource group. Set this true once you have confirmed it exists:
      az network watcher list -o table
    Leaving it false keeps the first apply simple.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for the Log Analytics workspace. 30 days is the free floor."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Applied to every resource. Useful for cost attribution later."
  type        = map(string)
  default = {
    project     = "hybrid-cloud-security-lab"
    environment = "lab"
    managed_by  = "terraform"
  }
}
