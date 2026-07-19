# ADR 0008 — Kueue reclaim tail-chase: documented limit, deferred fix

- **Status:** accepted (grilling session, 2026-07-19)
- **Context:** When the lending controller shrinks `borrowingLimit` at
  reclaim-window open, Kueue by design keeps already-admitted borrowing
  Workloads admitted — quota changes gate future admission, they do not
  evict. Observed consequence in game-day runs: borrower pods lose nodes
  (reclaim terminates them), re-pend, and re-admit the moment the window
  closes and the limit re-grows — a tail-chase where the same workload
  churns across every window instead of draining to the lender. Kueue's
  `reclaimWithinCohort` preemption does not fire here because our reclaim
  is wave-driven (time-triggered), not demand-driven — there is no incoming
  lender Workload to trigger preemption.
- **Decision:** **Accept the limitation at walking-skeleton stage; defer the
  fix; design it now.**
  - Skeleton verdict: reclaim SLO is met by node termination alone (198s
    ahead of ramp deadline in the 6/6 run); the tail-chase wastes scheduler
    cycles but does not break the lending contract.
  - Production design (unimplemented): at window-open the controller sets
    `spec.active=false` on borrowing Workloads in the affected ClusterQueue
    (deactivate → requeue), and re-activates at window-close. This drains
    borrowers for the window's duration instead of letting them thrash.
  - Rejected: carrying a Kueue fork or preemption-config contortions to make
    demand-driven preemption fire on a timer.
- **Consequences:**
  - `lending_reclaim_window_active` already exposes the window; the fix is
    controller-side only, no chart surgery expected.
  - Until implemented, borrower churn during windows is expected noise in
    game-day gate output — gates window their reads (`*_over_time`) partly
    for this reason.
  - Implementation rides after the GitOps/registry migrations (ADR 0006,
    0007) and their validation run.
