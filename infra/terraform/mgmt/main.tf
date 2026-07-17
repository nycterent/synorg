provider "aws" {
  region = var.region
}

# Management (hub) cluster — the single ArgoCD control plane that reconciles all
# spoke region clusters (KTD7, EKS Blueprints hub-and-spoke). Its data plane
# runs only ArgoCD; if the hub dies, spoke data planes keep serving and only
# reconciliation pauses. Time-critical lend/reclaim actuation is region-local
# and does not depend on this cluster.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Keep the hub's blast radius small: private API endpoint by default.
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = true

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.control_plane_subnet_ids

  # Access via EKS access entries (no aws-auth configmap). The Terraform caller
  # is granted cluster-admin to bootstrap ArgoCD once; thereafter git is the
  # only write path and human/agent kubectl access to the hub is break-glass.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    hub = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  tags = var.tags
}
