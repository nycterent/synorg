output "cluster_name" {
  description = "Hub cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Hub API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_arn" {
  description = "Hub cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the hub API server."
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN — used to scope the ArgoCD controller's IAM and per-spoke assume-role trust."
  value       = module.eks.oidc_provider_arn
}
