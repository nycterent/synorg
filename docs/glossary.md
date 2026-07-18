# Glossary

Terms with project-specific meaning. Canonical names live in
[conventions](conventions.md); this page defines the *concepts*.

**Availability arbitrage** — the platform's core multi-region rationale:
GPU capacity, instance families, and spot/reservation dynamics differ
between regions, and the system places GPU work where availability is
(ADR 0001). Regions are peers, not primary/backup.

**Warm floor** — the never-lent set of held GPU nodes that keeps customer
inference latency-safe. Held via ODCR, AZ-pinned, occupied by the balloon
Deployment when idle so the nodes stay provisioned and warm.

**Lendable pool** — held GPU capacity above the warm floor that the lending
controller offers to preemptible training inside a scheduled window, and
reclaims (drain + scrub) ahead of inference demand.

**Spoke** — a per-region workload cluster registered to the mgmt hub's
ArgoCD by cluster-secret label; each spoke carries its own pools, policies,
and region-local lending loop.

**Training arbitrage** — placing training jobs, at admission time, on
whichever region's spoke can admit them (MultiKueue dispatch, ADR 0002).
Never mid-run migration; a job restarts in-region against its region-local
checkpoint bucket.

**Stranded-wait** — training queue-wait accrued in one region while another
region's lendable pool has idle capacity (ADR 0003). The evidence-plane
metric whose P95 breaching one hour over a rolling week reopens the
checkpoint-relocation design.
