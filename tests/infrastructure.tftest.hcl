mock_provider "azurerm" {}

variables {
  subscription_id                 = "11111111-1111-1111-1111-111111111111"
  admin_group_object_ids          = ["22222222-2222-2222-2222-222222222222"]
  api_server_authorized_ip_ranges = ["203.0.113.10/32"]
}

run "demo_infrastructure" {
  command = plan

  assert {
    condition     = azurerm_resource_group.aks.location == "swedencentral" && azurerm_kubernetes_cluster.aks.location == "swedencentral"
    error_message = "The resource group and cluster must be in Sweden Central."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.aks.sku_tier == "Free" &&
      azurerm_kubernetes_cluster.aks.default_node_pool[0].vm_size == "Standard_D4s_v5" &&
      azurerm_kubernetes_cluster.aks.default_node_pool[0].node_count == 2 &&
      azurerm_kubernetes_cluster.aks.default_node_pool[0].only_critical_addons_enabled
    )
    error_message = "The demo must have two isolated D4s_v5 system nodes and Free control-plane tier."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.aks.node_provisioning_profile[0].mode == "Manual" &&
      azurerm_kubernetes_cluster_node_pool.application.vm_size == "Standard_F8s_v2" &&
      azurerm_kubernetes_cluster_node_pool.application.mode == "User" &&
      azurerm_kubernetes_cluster_node_pool.application.auto_scaling_enabled &&
      azurerm_kubernetes_cluster_node_pool.application.min_count == 0 &&
      azurerm_kubernetes_cluster_node_pool.application.max_count == 3 &&
      azurerm_kubernetes_cluster_node_pool.application.node_count == 1 &&
      azurerm_kubernetes_cluster_node_pool.application.name == "appf8" &&
      azurerm_kubernetes_cluster_node_pool.application.node_labels["workload"] == "hello-world"
    )
    error_message = "Use the standard autoscaler on the labeled F8s_v2 user pool, initially one node and bounded 0-3, without NAP."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.aks.auto_scaler_profile) == 0
    error_message = "Terraform must retain the baseline example; configure the priority expander through CLI after deployment."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.aks.role_based_access_control_enabled &&
      azurerm_kubernetes_cluster.aks.local_account_disabled &&
      azurerm_kubernetes_cluster.aks.azure_active_directory_role_based_access_control[0].azure_rbac_enabled &&
      azurerm_kubernetes_cluster.aks.api_server_access_profile[0].authorized_ip_ranges == toset(["203.0.113.10/32"]) &&
      azurerm_role_assignment.cluster_admin["22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin" &&
      azurerm_role_assignment.cluster_user["22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service Cluster User Role"
    )
    error_message = "Require Entra/Azure RBAC, group authorization, disabled local credentials, and API allowlisting."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.aks.network_profile[0].network_plugin == "azure" &&
      azurerm_kubernetes_cluster.aks.network_profile[0].network_plugin_mode == "overlay" &&
      azurerm_kubernetes_cluster.aks.network_profile[0].load_balancer_sku == "standard" &&
      azurerm_kubernetes_cluster.aks.network_profile[0].outbound_type == "loadBalancer"
    )
    error_message = "Use Azure CNI Overlay and a Standard Load Balancer with explicit outbound access."
  }
}

run "zero_initial_nodes" {
  command = plan

  variables {
    user_pool_scaling = {
      min_count     = 0
      max_count     = 3
      initial_count = 0
    }
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.application.node_count == 0
    error_message = "A user pool must support an initial node count of zero."
  }
}

run "reject_unrestricted_api" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "reject_invalid_api_cidr" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["not-a-cidr"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "reject_empty_admin_groups" {
  command = plan

  variables {
    admin_group_object_ids = []
  }

  expect_failures = [var.admin_group_object_ids]
}

run "reject_initial_count_outside_bounds" {
  command = plan

  variables {
    user_pool_scaling = {
      min_count     = 0
      max_count     = 3
      initial_count = 4
    }
  }

  expect_failures = [var.user_pool_scaling]
}

run "reject_fractional_nodes" {
  command = plan

  variables {
    user_pool_scaling = {
      min_count     = 0
      max_count     = 3
      initial_count = 0.5
    }
  }

  expect_failures = [var.user_pool_scaling]
}
