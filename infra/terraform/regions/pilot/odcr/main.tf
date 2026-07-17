provider "aws" {
  region = var.region
}

# Open ODCRs that match the attributes of the running ECS GPU instances so the
# capacity associates *in place* — the already-running instances fall into the
# reservation with no relaunch (instance_match_criteria = "open"). This is the
# capture step of KTD9/U15: hold the scarce GPU capacity under a reservation
# first, verify utilization == running count, and only then let U3 bind
# Karpenter NodePools to it and U13 carve ECS→EKS one instance at a time.
#
# Held capacity must never silently lapse (the program's never-release stop
# condition), so the reservations carry no end date (end_date_type = unlimited).
resource "aws_ec2_capacity_reservation" "held" {
  for_each = var.held_reservations

  instance_type           = each.value.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = each.value.availability_zone
  instance_count          = each.value.instance_count
  instance_match_criteria = "open"
  end_date_type           = "unlimited"

  tags = merge(var.tags, {
    "synorg.io/held-capacity" = "true"
    "synorg.io/ledger-id"     = each.key
  })

  # Never-release stop condition (KTD9/U15): removing a key from
  # var.held_reservations must not silently destroy a held reservation —
  # unreserved GPU capacity may not be reclaimable. Destroying one is a
  # deliberate, reviewed act, not a side effect of a map edit.
  lifecycle {
    prevent_destroy = true
  }
}
