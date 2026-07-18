variable "region" {
  description = "AWS region for the disposable e2e VPC (mirrors the cluster modules' default)."
  type        = string
  default     = "eu-west-1"
}
