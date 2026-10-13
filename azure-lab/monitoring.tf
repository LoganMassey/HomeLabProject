# ---------------------------------------------------------------------------
# Log Analytics
#
# This is the foundation for Microsoft Sentinel later. Sentinel is not a
# separate data store — it is a solution layered on a Log Analytics
# workspace, so this workspace is what you would onboard.
#
# Cost warning: Log Analytics bills on ingestion volume. Sentinel adds its
# own per-GB charge on top. Keep retention at the 30-day floor and watch the
# budget alert while you are learning what your log volume looks like.
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

# Storage account for flow logs. Name must be globally unique and
# lowercase-alphanumeric only, hence the random suffix.
resource "random_string" "sa_suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "flowlogs" {
  name                     = "${var.prefix}flow${random_string.sa_suffix.result}"
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Posture settings worth being able to justify in an interview.
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# VNet Flow Logs
#
# Note this targets the VNET, not an NSG. NSG Flow Logs are on a retirement
# path, so anything built now should use VNet Flow Logs. Being able to say
# why you chose one over the other is the kind of currency that reads well.
#
# Gated behind a variable because this needs a Network Watcher to already
# exist in the region. Confirm with:
#   az network watcher list -o table
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "regional" {
  count               = var.enable_flow_logs ? 1 : 0
  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "${var.prefix}-flowlog"
  network_watcher_name = data.azurerm_network_watcher.regional[0].name
  resource_group_name  = data.azurerm_network_watcher.regional[0].resource_group_name
  target_resource_id   = azurerm_virtual_network.lab.id
  storage_account_id   = azurerm_storage_account.flowlogs.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 7
  }

  # Traffic Analytics turns raw flow records into something queryable in
  # KQL. This is where the detection work actually happens.
  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.lab.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.lab.location
    workspace_resource_id = azurerm_log_analytics_workspace.lab.id
    interval_in_minutes   = 60
  }

  tags = var.tags
}
