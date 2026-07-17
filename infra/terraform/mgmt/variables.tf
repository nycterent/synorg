variable "region" {
  description = "AWS region for the management (hub) cluster."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name of the management EKS cluster (the ArgoCD hub)."
  type        = string
  default     = "synorg-mgmt"
}

variable "cluster_version" {
  description = "EKS control-plane version for the hub."
  type        = string
  default     = "1.33"
}

# Networking is a pre-existing layer (VPC lifecycle is separate from cluster
# lifecycle). The hub API endpoint is private by default (KTD7: the hub has
# fleet-wide write reach, so its access surface is kept small).
variable "vpc_id" {
  description = "VPC the hub cluster runs in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the hub node group (private)."
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the EKS control-plane ENIs."
  type        = list(string)
}

variable "cluster_endpoint_public_access" {
  description = "Expose the hub API server publicly. Off by default — the hub is a fleet-wide compromise target (KTD7)."
  type        = bool
  default     = false
}

# The hub runs only ArgoCD (HA-lite). No spoke workloads land here, so the node
# group is deliberately minimal.
variable "node_instance_types" {
  description = "Instance types for the hub node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_min_size" {
  description = "Minimum hub node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum hub node count."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired hub node count (HA-lite: two nodes across AZs)."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all hub resources."
  type        = map(string)
  default     = {}
}
