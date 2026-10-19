locals {
  location       = "swedencentral"
  user_pool_name = "appf8"
}

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = local.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  automatic_upgrade_channel         = "patch"
  node_os_upgrade_channel           = "NodeImage"
  role_based_access_control_enabled = true
  local_account_disabled            = true
  run_command_enabled               = false

  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_D4s_v5"
    node_count                   = 2
    type                         = "VirtualMachineScaleSets"
    os_sku                       = "Ubuntu"
    os_disk_type                 = "Managed"
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtmp"
    tags                         = var.tags

    upgrade_settings {
      max_surge = "1"
    }
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  tags = var.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "application" {
  name                  = local.user_pool_name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_F8s_v2"
  mode                  = "User"
  os_type               = "Linux"
  os_sku                = "Ubuntu"
  os_disk_type          = "Managed"

  auto_scaling_enabled = true
  min_count            = var.user_pool_scaling.min_count
  max_count            = var.user_pool_scaling.max_count
  node_count           = var.user_pool_scaling.initial_count

  node_labels = {
    workload = "hello-world"
  }

  upgrade_settings {
    max_surge = "1"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = var.admin_group_object_ids

  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = var.admin_group_object_ids

  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
  principal_type       = "Group"
}
