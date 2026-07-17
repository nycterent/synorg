output "cluster_name" {
  description = "Pilot cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Pilot API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_arn" {
  description = "Pilot cluster ARN — registered as an ArgoCD spoke on the hub."
  value       = module.eks.cluster_arn
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN for the pilot."
  value       = module.eks.oidc_provider_arn
}

# Consumed by the Karpenter controller Helm values and by the EC2NodeClass
# `role` field (clusters/pilot/karpenter/) — the node role Karpenter attaches to
# provisioned GPU/web instances.
output "karpenter_node_iam_role_name" {
  description = "IAM role name Karpenter attaches to provisioned nodes."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_controller_iam_role_arn" {
  description = "IRSA role ARN for the Karpenter controller."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name Karpenter watches for spot/rebalance interruptions."
  value       = module.karpenter.queue_name
}
