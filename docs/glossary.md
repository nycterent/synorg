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

**Utilization-of-held** — GPU-hours allocated ÷ GPU-hours held, per pool
(ADR 0005). The number that decides whether the held book earns its keep;
floor target 70% on a rolling month.

**Idle-burn** — $/day of held-but-unallocated capacity at on-demand rates
(ADR 0005). The premium the lending machine exists to offset.

**Lending window** — the scheduled interval (`opensAt`→`closesAt` in the
lending schedule) during which the lendable pool may carry training. Opening
flips the `lent` marker on across lendable nodes; closing is the deadline by
which every reclaim wave must have returned capacity.

**Reclaim wave** — one staged capacity-return leg inside a lending window,
its lead time measured back from the window's close. Waves drain and scrub
lent nodes ahead of the inference ramp.

**Reclaim phase** — the tail of a lending window, from the first reclaim
wave's start until the window closes. Borrower drain is in force for the
whole phase. (The recording rule `lending_reclaim_window_active` predates
this vocabulary and is a known misnomer: its expression flags "some node is
currently lent", i.e. lending-active, not reclaim-in-progress. Rename
pending; readers of dashboards should translate.)

**Borrower drain** — during the reclaim phase, the lending controller
deactivates every borrowing Workload in the borrowing ClusterQueue
(ADR 0008); on phase exit they are reactivated and pend until the next
window's quota admits them. Scope is the whole queue, not just Workloads on
reclaimed nodes — sound only while taints pin training to the lendable pool.

**Tail-chase** — the pathology borrower drain eliminates: without it,
admitted borrowers survive the borrowing-limit shrink, lose their nodes to
reclaim, re-pend, and re-admit the moment the window reopens — the same
workload churning across every window instead of draining to the lender
(ADR 0008).
