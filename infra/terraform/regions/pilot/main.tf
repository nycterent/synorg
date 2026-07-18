provider "aws" {
  region = var.region
}

# Pilot spoke cluster (R8 first region). Holds the GPU fleet modeled in git:
# warm-floor (never lent), lendable GPU, and web pools — all Karpenter-managed
# and bound to the held ODCRs captured by U15. Reconciled by the U2 hub.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = true

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.control_plane_subnet_ids

  enable_cluster_creator_admin_permissions = true

  # Karpenter discovers this cluster's node security group by tag; subnets are
  # tagged with the same key at the VPC layer.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_min_size
      max_size       = var.system_node_max_size
      desired_size   = var.system_node_desired_size
    }
  }

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# Karpenter IAM/IRSA + interruption SQS queue. The controller runs on the system
# node group; NodePools/EC2NodeClass (git-managed, clusters/pilot/karpenter/) do
# the actual provisioning from the held reservations.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # v1 Karpenter (v1.x line, KTD9) IAM permissions.
  enable_v1_permissions = true

  # IRSA trust for the controller service account (§4.5 installs the chart
  # into kube-system with SA "karpenter"); without this the module defaults
  # to Pod Identity and AssumeRoleWithWebIdentity is denied (found live).
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  # Node role Karpenter attaches to provisioned instances.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = var.tags
}

# Scope the Karpenter controller to the held reservations captured by U15. This
# is the concrete U3→U15 binding: the controller may launch instances *into* the
# held ODCRs (reserved capacity is preferred over on-demand). Only attached when
# the ODCR ARNs are wired in (../odcr `reservation_arns`).
data "aws_iam_policy_document" "held_capacity" {
  count = length(var.odcr_reservation_arns) > 0 ? 1 : 0

  # Discovery is account-wide (DescribeCapacityReservations has no resource-level
  # scoping); consumption is scoped to exactly the held reservation ARNs.
  statement {
    sid       = "DiscoverCapacityReservations"
    effect    = "Allow"
    actions   = ["ec2:DescribeCapacityReservations"]
    resources = ["*"]
  }

  statement {
    sid       = "LaunchIntoHeldReservations"
    effect    = "Allow"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = var.odcr_reservation_arns
  }
}

resource "aws_iam_role_policy" "karpenter_held_capacity" {
  count = length(var.odcr_reservation_arns) > 0 ? 1 : 0

  name   = "${var.cluster_name}-karpenter-held-capacity"
  role   = module.karpenter.iam_role_name
  policy = data.aws_iam_policy_document.held_capacity[0].json
}
