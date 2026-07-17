# Capacity transition ledger

The auditable record of held GPU capacity moving from ECS ASGs to the EKS fleet.
It exists to prove one invariant across the whole transition:

> **Zero net release.** Held-capacity instance count never drops between two
> consecutive ledger rows. Released GPU capacity may never come back, so every
> carve step must show the reservation holding the capacity *before* an ECS
> instance is terminated (verify-before-terminate).

The ledger is append-only. One row per capacity-affecting action (reservation
create/modify, carve increment, floor change). Each row links to the evidence
(the PR + the reservation-utilization snapshot) that justifies it.

## Schema

| Field | Meaning |
|---|---|
| `date` | ISO-8601 date of the action. |
| `region` | AWS region (pilot: `eu-west-1`). |
| `reservation` | ODCR ledger id (`synorg.io/ledger-id` tag, e.g. `p5-48xlarge-a`). |
| `instances-held` | Reservation capacity held **after** this action (utilization-verified). |
| `delta` | Change vs the previous row for this reservation (`+n` / `-n` / `0`). A carve step is `0`: an EKS instance takes the ODCR slot the ECS instance vacated. A raw `-n` with no matching `+n` is a release — forbidden. |
| `evidence-link` | PR URL + reservation-utilization evidence (e.g. `describe-capacity-reservations` before/after, Karpenter metrics). |

## Invariant check

For each `reservation`, the running total of `delta` must be **≥ 0 at every
row** and must equal `instances-held`. A carve wave is correct only if the sum
of its `delta` values is `0` (capacity moved, not lost). Any negative running
total is a stop condition — halt the transition, do not proceed.

## Ledger

<!-- Append rows here. Newest last. Placeholder rows below are illustrative and
     carry no evidence link — replace when the real capture/carve lands. -->

| date | region | reservation | instances-held | delta | evidence-link |
|---|---|---|---|---|---|
| _pending_ | eu-west-1 | p5-48xlarge-a | 4 | +4 | _capture PR — reservation utilization == 4 running ECS instances_ |
| _pending_ | eu-west-1 | g6e-12xlarge-a | 8 | +8 | _capture PR — reservation utilization == 8 running ECS instances_ |

## How rows are produced

- **Capture (U15):** `terraform apply` in `infra/terraform/regions/pilot/odcr/`
  creates the open reservations; the ledger row records the verified utilization.
- **Carve (U13/U15):** each increment follows `runbooks/capacity-carve.md`; the
  row's `delta` is `0` (ECS slot → EKS slot within the same reservation).
- **Floor / fleet-shape changes:** recorded with the PR that changed
  `var.held_reservations` or the warm-floor size.
