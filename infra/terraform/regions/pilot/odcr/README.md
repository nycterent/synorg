# Held-capacity capture (U15)

Open On-Demand Capacity Reservations (ODCRs) that capture the scarce held GPU
capacity **in place** before any migration touches it. This is the riskiest
operation in the program: released GPU capacity may never return, so the
invariant is **zero net release at every step**.

## What this does

For each held GPU flavor+AZ (`var.held_reservations`) it creates one **open**
ODCR (`instance_match_criteria = "open"`) matching the attributes of the running
ECS GPU instances. An open reservation associates the *already-running*
instances with no relaunch — the capacity is captured where it sits. The
reservations have no end date so the hold cannot silently lapse.

## Capture-in-place, then verify-before-terminate

1. `terraform apply` creates the reservations sized to the **current running**
   ECS instance count per flavor+AZ (`instance_count`).
2. Because the reservation is *open* and the attributes match, the running
   instances fall into it automatically — no instance is relaunched.
3. **Gate:** confirm each reservation's live utilization equals the running
   instance count (`declared_instance_counts` output) *before anything else
   proceeds*. If a reservation does not show its capacity held, stop — do not
   terminate anything.

Only after the gate passes do downstream units act:

- **U3** binds Karpenter NodePools to these reservations via the
  `EC2NodeClass` `capacityReservationSelectorTerms` (selects on the
  `synorg.io/held-capacity=true` tag — see `reservation_selector_tag`).
- **U13** carves ECS→EKS one instance at a time, always terminating *after* the
  reservation demonstrably holds that instance's capacity
  (`runbooks/capacity-carve.md`).

## Wiring to U3

`reservation_ids` / `reservation_selector_tag` feed the pilot region's Karpenter
`EC2NodeClass`. Tag-based selection means adding a reservation here does not
require editing any manifest.

## Ledger

Every reservation change is recorded in
[`docs/capacity-transition.md`](../../../../../docs/capacity-transition.md) with
before/after utilization evidence. The ledger is the auditable proof of the
zero-net-release invariant.

## Apply is out of scope for validation

`terraform validate`/`fmt` are run in CI; `apply` is a human-gated, evidence-attached
step (never auto-applied) because it touches live capacity.
