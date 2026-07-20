# Runbook: capacity carve (ECS → EKS, zero net release)

Executable playbook for moving one held GPU instance from ECS to EKS without
ever dropping held capacity. Run one increment per invocation, tied to a U13
migration wave. **Verify-before-terminate at every single step; any failed hold
aborts the step, never the capacity.**

![Verify-before-terminate carve loop: create the open ODCR, then per wave cordon and drain one ECS instance, terminate it, verify the reservation still holds its capacity, launch an EKS nodeclaim into the freed slot, and confirm net count unchanged; every verify gate that fails routes to a single ABORT that leaves the ECS instance running and never releases capacity](../docs/assets/diagrams/capacity-carve.svg)

*Figure 1 — Verify-before-terminate carve loop — every failed verify gate routes to a single ABORT that never releases capacity.*

Preconditions: the open ODCRs exist and are utilization-verified (U15,
`infra/terraform/regions/pilot/odcr/`), the pilot cluster + Karpenter are live
(U3), and the reservation's `synorg.io/held-capacity=true` tag is set.

## Variables

```bash
export REGION=eu-west-1
export LEDGER_ID=p5-48xlarge-a          # synorg.io/ledger-id tag value
export RESERVATION_ID=cr-xxxxxxxxxxxxxxxxx   # from `terraform output reservation_ids`
export ECS_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx   # the ECS GPU instance to carve
```

## Step 0 — Create the open reservation and verify capture in place

Only needed once per flavor, before the first carve. Skip if already captured.

```bash
cd infra/terraform/regions/pilot/odcr
terraform apply        # human-gated; touches live capacity
RESERVATION_ID=$(terraform output -json reservation_ids | jq -r ".\"$LEDGER_ID\"")
EXPECTED=$(terraform output -json declared_instance_counts | jq -r ".\"$LEDGER_ID\"")
```

Assert the reservation shows the running instances held (utilization == running
count). **Abort if not equal — do not proceed to any termination.**

```bash
aws ec2 describe-capacity-reservations --region "$REGION" \
  --capacity-reservation-ids "$RESERVATION_ID" \
  --query 'CapacityReservations[0].{total:TotalInstanceCount,available:AvailableInstanceCount}'
# held = total - available. Require: (total - available) == EXPECTED
```

Record the row in `docs/capacity-transition.md` (`+n`, evidence = this output).

## Step 1 — Cordon and drain the ECS instance

Stop new placements, let running work bleed off (respect the training checkpoint
contract: 120 s grace so any in-flight training final-checkpoints).

```bash
# ECS: drain the container instance (STgnDeployment-safe)
aws ecs update-container-instances-state --region "$REGION" \
  --cluster "$ECS_CLUSTER" --container-instances "$ECS_CONTAINER_INSTANCE_ARN" \
  --status DRAINING
# wait until runningTasksCount == 0 (poll)
```

## Step 2 — Terminate the ECS instance and confirm capacity stays held

Terminating an *open*-reservation instance returns its slot to the reservation
as **available** — the held count does not drop.

```bash
aws ec2 terminate-instances --region "$REGION" --instance-ids "$ECS_INSTANCE_ID"
# After termination, assert total is unchanged and the slot is now available:
aws ec2 describe-capacity-reservations --region "$REGION" \
  --capacity-reservation-ids "$RESERVATION_ID" \
  --query 'CapacityReservations[0].{total:TotalInstanceCount,available:AvailableInstanceCount}'
# Require: total unchanged; available increased by exactly 1.
```

**Abort-on-failed-hold:** if `total` dropped, the capacity was released — STOP.
Do not launch the EKS node; open an incident. The reservation, not the instance,
is the thing being protected.

## Step 3 — Launch an EKS nodeclaim into the freed reservation slot

Karpenter provisions a node from the reservation (capacity-type `reserved`)
because the NodePool prefers reserved capacity and the EC2NodeClass selects this
reservation by tag.

```bash
# Trigger provisioning by scheduling a pod that tolerates the target pool taint,
# or let the warm-floor balloon / lendable demand pull a node. Then:
kubectl get nodeclaims -o wide | grep "$LEDGER_ID"
kubectl get nodes -l 'karpenter.sh/capacity-type=reserved' -o wide
```

Assert the new node consumed a reservation slot (reservation `available`
decreased by 1, back to the Step 0 held level).

## Step 4 — Assert net count and record the ledger row

```bash
aws ec2 describe-capacity-reservations --region "$REGION" \
  --capacity-reservation-ids "$RESERVATION_ID" \
  --query 'CapacityReservations[0].{total:TotalInstanceCount,available:AvailableInstanceCount}'
# Require: total == EXPECTED AND available == same as before this carve step.
```

Held count is unchanged: one ECS slot became one EKS slot inside the same
reservation. Record a `delta: 0` row in `docs/capacity-transition.md` linking
this PR + the before/after utilization snapshots.

## Abort semantics (any step)

- A reservation that fails to show capacity held → **abort the step**, leave the
  ECS instance running, do not terminate. The invariant is capacity, not
  progress.
- Never batch increments: one instance per carve so a failure loses at most one
  slot's worth of certainty, and the ledger stays step-auditable.
