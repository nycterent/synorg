variable "region" {
  description = "AWS region hosting the pilot cluster and its checkpoint store (EU pilot)."
  type        = string
  default     = "eu-west-1"
}

# Global-unique S3 bucket name. Placeholder default; the real per-env name is set
# in the region's tfvars before apply (mirrors the odcr module convention).
variable "bucket_name" {
  description = "Name of the S3 bucket backing the shared training checkpoint store."
  type        = string
  default     = "synorg-pilot-training-checkpoints"
}

# Keep one fallback generation of checkpoints, then reclaim. A run needs only the
# latest good checkpoint plus one previous version (partial-final-checkpoint
# fallback), so retention is short by design.
variable "checkpoint_retention_days" {
  description = "Days to retain noncurrent (superseded) checkpoint object versions before expiry."
  type        = number
  default     = 7

  validation {
    condition     = var.checkpoint_retention_days > 0
    error_message = "checkpoint_retention_days must be positive."
  }
}

# FSx for Lustre scratch tier — placeholder, gated OFF by default. The single
# versioned+encrypted S3 bucket is the default checkpoint store; enable this only
# if a game-day shows the concurrent-final-checkpoint burst (every lent node
# flushing inside the 120 s grace) needs sustained low-latency POSIX throughput
# in front of S3. No resource is created while this is false — this variable is
# the documented seam for that future tier, nothing more.
variable "enable_fsx" {
  description = "Placeholder toggle for an FSx for Lustre scratch tier in front of S3. Off by default; no resource is created until a throughput game-day justifies it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags merged onto every resource (attribution)."
  type        = map(string)
  default     = {}
}
