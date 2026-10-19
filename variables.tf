variable "subscription_id" {
  description = "Azure subscription ID in the tenant containing the administrator groups."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group Terraform will create."
  type        = string
  default     = "rg-aks-hello-sweden"
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,89}$", var.resource_group_name))
    error_message = "Use 1-90 letters, numbers, underscores, or hyphens, starting with a letter or number."
  }
}

variable "cluster_name" {
  description = "AKS name, also used as its DNS prefix."
  type        = string
  default     = "aks-hello-sweden"
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,52}[a-zA-Z0-9])?$", var.cluster_name))
    error_message = "Use 1-54 letters, numbers, or hyphens, starting and ending with a letter or number."
  }
}

variable "admin_group_object_ids" {
  description = "Existing Microsoft Entra group object IDs to grant AKS administration and credential retrieval."
  type        = set(string)
  nullable    = false

  validation {
    condition = length(var.admin_group_object_ids) > 0 && alltrue([
      for id in var.admin_group_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Provide at least one existing Entra administrator group object ID, in UUID format."
  }
}

variable "api_server_authorized_ip_ranges" {
  description = "Public IPv4 CIDRs allowed to reach the AKS management API; does not restrict the web app."
  type        = set(string)
  nullable    = false

  validation {
    condition = length(var.api_server_authorized_ip_ranges) > 0 && length(var.api_server_authorized_ip_ranges) <= 200 && alltrue([
      for cidr in var.api_server_authorized_ip_ranges :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) > 0, false)
    ])
    error_message = "Provide 1-200 valid IPv4 CIDRs for your public egress IPs; unrestricted /0 access is not allowed."
  }
}

variable "kubernetes_version" {
  description = "Optional supported GA version in Sweden Central. Null lets AKS select its recommended version at creation."
  type        = string
  default     = null

  validation {
    condition     = var.kubernetes_version == null || can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "Use a GA Kubernetes version such as major.minor or major.minor.patch, or leave it null."
  }
}

variable "user_pool_scaling" {
  description = "Standard AKS cluster-autoscaler bounds and initial user node count. Initial count is ignored after creation."
  type = object({
    min_count     = number
    max_count     = number
    initial_count = number
  })
  default = {
    min_count     = 0
    max_count     = 3
    initial_count = 1
  }
  nullable = false

  validation {
    condition = alltrue([
      for count in [var.user_pool_scaling.min_count, var.user_pool_scaling.max_count, var.user_pool_scaling.initial_count] :
      count == floor(count)
      ]) && (
      var.user_pool_scaling.min_count >= 0 &&
      var.user_pool_scaling.max_count >= 1 &&
      var.user_pool_scaling.max_count <= 1000 &&
      var.user_pool_scaling.min_count <= var.user_pool_scaling.initial_count &&
      var.user_pool_scaling.initial_count <= var.user_pool_scaling.max_count
    )
    error_message = "Use whole-node counts with 0 <= min_count <= initial_count <= max_count <= 1000 and max_count >= 1."
  }
}

variable "tags" {
  description = "Tags applied to the resource group, AKS, and node pools."
  type        = map(string)
  default = {
    environment = "demo"
    workload    = "hello-world"
    managed_by  = "terraform"
  }
  nullable = false
}
