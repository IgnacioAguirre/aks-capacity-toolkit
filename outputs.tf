output "resource_group_name" {
  description = "Resource group created by Terraform."
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS name for az aks get-credentials."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "cluster_id" {
  description = "AKS resource ID."
  value       = azurerm_kubernetes_cluster.aks.id
}

output "location" {
  description = "Azure deployment region."
  value       = azurerm_resource_group.aks.location
}

output "user_pool_name" {
  description = "F8s_v2 application node pool."
  value       = azurerm_kubernetes_cluster_node_pool.application.name
}

output "kubernetes_version" {
  description = "Actual Kubernetes version reported by AKS."
  value       = azurerm_kubernetes_cluster.aks.current_kubernetes_version
}
