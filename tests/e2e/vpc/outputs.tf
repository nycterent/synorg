output "vpc_id" {
  description = "Disposable e2e VPC id — exported as TF_VAR_vpc_id for the mgmt + pilot modules."
  value       = aws_vpc.e2e.id
}

output "subnet_ids" {
  description = "Public subnet ids (two AZs) — exported as TF_VAR_subnet_ids and TF_VAR_control_plane_subnet_ids."
  value       = aws_subnet.public[*].id
}
