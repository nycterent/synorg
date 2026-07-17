# Reservation ids keyed by ledger id. Consumed by U3's Karpenter EC2NodeClass
# (capacityReservationSelectorTerms) and by the capacity ledger evidence links.
output "reservation_ids" {
  description = "ODCR ids keyed by ledger id."
  value       = { for k, r in aws_ec2_capacity_reservation.held : k => r.id }
}

# ARNs for IAM scoping (grant Karpenter's node role ec2:*CapacityReservation on
# exactly these ARNs) and for audit.
output "reservation_arns" {
  description = "ODCR ARNs keyed by ledger id."
  value       = { for k, r in aws_ec2_capacity_reservation.held : k => r.arn }
}

# The tag Karpenter selects the held fleet by. U3's EC2NodeClass
# capacityReservationSelectorTerms match this tag, so new reservations join the
# fleet without editing any manifest (discovery-by-tag, like subnets/SGs).
output "reservation_selector_tag" {
  description = "Tag key/value that binds the held fleet to Karpenter."
  value       = { "synorg.io/held-capacity" = "true" }
}

# Declared vs actual is the verify-before-terminate gate: the carve runbook
# asserts each reservation's live utilization equals this count before any
# instance is terminated.
output "declared_instance_counts" {
  description = "Declared held instance count per ledger id (expected reservation utilization)."
  value       = { for k, r in var.held_reservations : k => r.instance_count }
}
