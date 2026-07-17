variable "region" {
  description = "AWS region for the pilot spoke cluster. EU pilot per R8 (data gravity + EU residency)."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name of the pilot spoke EKS cluster."
  type        = string
  default     = "synorg-pilot"
}

variable "cluster_version" {
  description = "EKS control-plane version for the pilot."
  type        = string
  default     = "1.33"
}

variable "vpc_id" {
  description = "VPC the pilot cluster runs in (co-located with training data — Assumption 1)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for Karpenter-managed nodes and the system node group."
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the EKS control-plane ENIs."
  type        = list(string)
}

# Minimal system node group runs Karpenter, CoreDNS, and cluster add-ons only.
# All GPU/web capacity is Karpenter-provisioned (held fleet + web pool).
variable "system_node_instance_types" {
  description = "Instance types for the system node group (Karpenter + add-ons)."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "system_node_min_size" {
  description = "Minimum system node count."
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum system node count."
  type        = number
  default     = 3
}

variable "system_node_desired_size" {
  description = "Desired system node count."
  type        = number
  default     = 2
}

# Wired from ../odcr module's `reservation_arns` output (via CI/tfvars or a
# terraform_remote_state read). Used to scope Karpenter's node IAM to exactly the
# held reservations — U15's capture precedes this binding (U3 depends on U15).
variable "odcr_reservation_arns" {
  description = "Held ODCR ARNs (from infra/terraform/regions/pilot/odcr outputs) the pilot fleet may consume."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all pilot resources."
  type        = map(string)
  default     = {}
}
