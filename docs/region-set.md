# Region set (R8 derivation)

Which regions the platform runs in is **derived**, not chosen ad hoc. A new
region is a Terraform module instantiation plus an overlay directory that the
ApplicationSet picks up — no new cluster-side steps. This doc defines the
predicate that admits a region and the rules that keep regions from diverging.

## Derivation predicate

A candidate region is admitted **iff all three hold** (logical AND — any one
failing disqualifies it):

```
region ∈ set  ⟺  GPU availability  ∧  training-data gravity  ∧  EU residency
```

- **GPU availability** — the required GPU instance families are actually
  obtainable there at the needed scale (ODCR quota grantable, acceptable AWS lead
  time for scarce families). Scarcity surfaces here as evidence (KTD5), before
  any workload is promised.
- **Training-data gravity** — the training data this region would serve/produce
  already lives (or must live) near it. Compute follows data; a region with no
  data-gravity reason imports egress cost and latency for nothing.
- **EU residency** — the region satisfies the residency constraint for the
  customer data it would host. Encoded as a U5 policy: customer-data workloads
  are **denied at validate time** if they target a non-compliant region (the
  tenancy/residency guard), so a residency miss is caught pre-merge, not at
  runtime.

All three are necessary; none alone is sufficient. A region with GPUs but wrong
residency is out; a compliant region with no data gravity is out.

## Overlay-only rule

Every region after the pilot is expressed as an **overlay** under
`clusters/<region>/` plus a Terraform instantiation under
`infra/terraform/regions/<region>/`. The only thing that may differ between two
regions is **values** — sizes, counts, region-local schedules.

> **Divergence beyond values is a defect.** If two region overlays differ in
> structure — different templates, extra resources, bespoke wiring — that is a
> bug to fix in the shared base, not a legitimate per-region customization. The
> U12 verification asserts the diff between region overlays is values-only.

This keeps the region set homogeneous: a fix or policy change lands once in the
base and reaches every region, and reasoning about "what runs in region N" never
requires reading region-specific logic.

## Per-region warm floor

The never-lent GPU **warm floor** (`gpu-warm-floor` NodePool, `docs/conventions.md`)
is sized **per region from that region's own measured demand** — it is **not**
copied from the pilot. Each region's floor holds its own render-path latency
guarantee (R2) against its own traffic. Sizing a new region's floor reuses the
pilot's method (measure demand → size floor), never the pilot's number.

## Region-local lending

Lending windows are **region-local**. Each region's schedule
(`clusters/<region>/lending/schedule.yaml`) follows that region's off-peak, not a
global clock — the "whose night is it" concern (Assumption 3). A borrowing window
that is night in one region is not imposed on another. Windows are revisited as
global-customer data arrives, but the default is: each region lends on its own
off-peak, independently.
