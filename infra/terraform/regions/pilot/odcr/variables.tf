variable "region" {
  description = "AWS region holding the ECS GPU fleet being captured in place (EU pilot)."
  type        = string
  default     = "eu-west-1"
}

# One entry per held GPU flavor/AZ. instance_count MUST equal the running ECS
# instance count for that flavor+AZ: an "open" reservation only associates the
# already-running instances in place (zero relaunch) when the count matches, and
# the carve never terminates an instance before the reservation shows its
# capacity held (verify-before-terminate — U15, runbooks/capacity-carve.md).
# Defaults are placeholders; real counts come from the capture inventory and are
# recorded in docs/capacity-transition.md before apply.
variable "held_reservations" {
  description = "Open On-Demand Capacity Reservations to create, keyed by a stable ledger id."
  type = map(object({
    instance_type     = string
    availability_zone = string
    instance_count    = number
  }))

  default = {
    p5-48xlarge-a = {
      instance_type     = "p5.48xlarge"
      availability_zone = "eu-west-1a"
      instance_count    = 4
    }
    g6e-12xlarge-a = {
      instance_type     = "g6e.12xlarge"
      availability_zone = "eu-west-1a"
      instance_count    = 8
    }
  }

  # instance_count must be positive — a zero-count reservation holds nothing and
  # would silently break the zero-net-release invariant.
  validation {
    condition     = alltrue([for r in var.held_reservations : r.instance_count > 0])
    error_message = "Every held reservation must hold at least one instance (instance_count > 0)."
  }
}

variable "tags" {
  description = "Tags merged onto every reservation (attribution + ledger cross-reference)."
  type        = map(string)
  default     = {}
}
