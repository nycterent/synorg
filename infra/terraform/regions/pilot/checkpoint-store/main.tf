provider "aws" {
  region = var.region
}

# Shared checkpoint store for preemptible training (U7 / KTD12). The training-job
# chart mounts this and publishes it as CHECKPOINT_DIR; jobs checkpoint every
# <=5 min and, on preemption, flush one final checkpoint inside the 120 s grace.
#
# Sizing / throughput note (worst case): the reclaim wave can preempt every lent
# node at once, so in the worst case *all* lent GPU nodes final-checkpoint
# concurrently inside the same 120 s window. With the lendable pool capped at 64
# GPUs and multi-GB checkpoint shards per node, that is a burst of tens of GB of
# writes in ~2 minutes. S3 absorbs this: aggregate PUT throughput scales
# horizontally with key prefix, and each node writes under its own team/job
# prefix, so there is no single-object hot spot. If a future game-day shows the
# burst needs sustained low-latency POSIX throughput instead, enable the FSx for
# Lustre placeholder (var.enable_fsx) as a scratch tier in front of S3 — off by
# default so the default footprint stays a single versioned, encrypted bucket.
resource "aws_s3_bucket" "checkpoints" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    "synorg.io/purpose" = "training-checkpoints"
  })
}

# Versioning: a corrupted or partial final checkpoint (killed mid-flush at the
# 120 s boundary) must never overwrite the last-good one — resume falls back to
# the previous version.
resource "aws_s3_bucket_versioning" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE at rest (KMS). bucket_key_enabled cuts KMS request cost under the
# concurrent-final-checkpoint write burst.
resource "aws_s3_bucket_server_side_encryption_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Checkpoints are internal training state — never public.
resource "aws_s3_bucket_public_access_block" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reclaim older checkpoint versions so the bucket does not grow without bound:
# a training run only ever needs the latest good checkpoint plus one fallback.
resource "aws_s3_bucket_lifecycle_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    id     = "expire-stale-checkpoint-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.checkpoint_retention_days
    }
  }
}
