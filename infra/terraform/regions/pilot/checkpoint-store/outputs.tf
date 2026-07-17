# Bucket name/ARN consumed by the training platform: the training-job pods reach
# this bucket (via Mountpoint-S3 CSI or the trainer's S3 client under an IRSA
# role) at the path published as CHECKPOINT_DIR. The ARN scopes that IRSA policy
# to exactly this bucket.
output "bucket_name" {
  description = "Name of the checkpoint-store S3 bucket."
  value       = aws_s3_bucket.checkpoints.id
}

output "bucket_arn" {
  description = "ARN of the checkpoint-store S3 bucket (for IRSA policy scoping)."
  value       = aws_s3_bucket.checkpoints.arn
}

# Whether the FSx scratch tier is engaged. Always false until a throughput
# game-day flips var.enable_fsx; surfaced so downstream wiring can branch without
# re-reading the variable.
output "fsx_enabled" {
  description = "True when the optional FSx for Lustre scratch tier is enabled (placeholder; default false)."
  value       = var.enable_fsx
}
