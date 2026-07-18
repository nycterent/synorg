# ADR 0003 — Checkpoints are sticky; relocation waits for a measured trigger

- **Status:** accepted (grilling session, 2026-07-18)
- **Context:** ADR 0002 arbitrages training at placement time and pins a
  running job to its region-local checkpoint bucket. The asymmetry: a job
  with days of checkpoints in region A queues there even while region B
  sits idle. Moving a 1 TB checkpoint costs roughly $20 of cross-region
  transfer and under an hour — often strictly cheaper than hours of a
  stalled multi-GPU job — but relocation machinery (cross-region copy,
  resume-from-remote, policy knobs) is real complexity.
- **Decision:** **Sticky forever, with a written revisit trigger.**
  - A checkpointed job never changes region; only new jobs arbitrage
    (phase-1 minimalism, consistent with ADR 0002's no-mid-run-migration).
  - The stranded-work scenario is made *measurable now*: the evidence plane
    gains a first-class metric — training queue-wait accrued in one region
    while another region's lendable pool has idle capacity
    (`cross-region stranded-wait`).
  - **Revisit trigger:** stranded-wait exceeding one hour at P95 over a
    rolling week opens the design for threshold relocation (option b:
    relocate when expected wait x stalled-GPU value exceeds egress cost
    plus transfer delay). Continuous replication (option c) stays rejected
    absent a residency or DR driver — it pays egress on every checkpoint
    for mobility that is rarely exercised.
- **Consequences:**
  - No relocation machinery is built until the metric demands it; the
    upgrade decision is data-driven, not speculative.
  - The metric lands with the second spoke (it is cross-region by
    definition) and belongs in the evidence plane next to GPU-hour
    attribution.
  - Checkpoint cadence (the 120 s checkpoint-grace design) bounds lost
    work per reclaim, not per relocation — unchanged by this ADR.
