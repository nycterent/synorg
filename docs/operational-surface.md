# Operational surface — what you now operate, worst offenders first

Adopting synorg means owning a composed system, not one component. This is the
honest map of that surface: every moving part you now run, what it does, how it
fails, roughly how often that failure reaches on-call, and the runbook that
covers it. Read it top-down — the table is ordered by **bite frequency**, so the
first rows are what you'll actually touch.

None of these are synorg inventions except the lending controller; the platform's
novelty is in how they're *composed*, not in re-implementing a scheduler. That
composition is the thing to reason about.

| Component | What it does | How it fails | Bite | First runbook |
| --- | --- | --- | --- | --- |
| **Lending controller** (bash v0) | Actuates the lend/reclaim lifecycle from the git schedule — the novel piece | Wedged (stale heartbeat), reclaim runs late, or quota patch not landing | **High** — it's the new muscle | [Training not admitting](../runbooks/operations.md#training-not-admitting--normal-or-wedged); [capacity carve](../runbooks/capacity-carve.md) |
| **Kueue** | Admits borrowing training against the schedule-driven quota | Job stays suspended (usually *normal* — no headroom), or a Workload wedges | **High** — the #1 false alarm | [Training not admitting](../runbooks/operations.md#training-not-admitting--normal-or-wedged); [onboarding](../runbooks/training-onboarding.md) |
| **Karpenter** | Provisions the warm-floor / lendable / web pools; scrub = NodeClaim delete | Won't provision (quota/capacity), node stuck, GPU auto-repair unreliable | **Medium** | [node scrub](../runbooks/node-scrub.md); [quarantine](../runbooks/gpu-node-quarantine.md) |
| **Warm floor / balloon** | The never-lent latency buffer that keeps inference safe | Floor sized too small → render-start p95 breaches during ramp | **Medium** | [operations: resize warm floor](../runbooks/operations.md#routine); [preemption storm](../runbooks/operations.md#preemption-storm-at-morning-ramp) |
| **Prometheus + DCGM** (evidence plane) | SLO series + per-GPU health; every gate reads it | Scrape targets down → no evidence → no verdict (a run with no evidence *is* a failure) | **Medium** | [e2e-gpu-run: DCGM relabel / KSM allowlist](../runbooks/e2e-gpu-run.md) |
| **Checkpoint store** (S3 / FSx) | Durable checkpoints so preemption costs ≤1 interval | PVC not `Bound`, throughput floor missed | **Low–Medium** | [onboarding Step 4](../runbooks/training-onboarding.md) |
| **ArgoCD hub** | Reconciles every spoke from git — the only write path | Hub outage: reconcile pauses; spokes keep serving and lending (region-local) | **Low** — rare, and degraded-safe | [operations: hub outage](../runbooks/operations.md#hub-outage) |
| **ODCR** (held reservations) | The capacity insurance the lending machine offsets | Reservation lost or ledger drift (net capacity released) | **Low but high-cost** | [capacity carve](../runbooks/capacity-carve.md); ADR 0005 |
| **Kyverno + VAP** | Admission policy — the capability tiers' hard-deny lane | Denies a valid change, or a policy gap lets a bad one through | **Low** | [capability tiers](capability-tiers.md); `policies/README.md` |

## How to read the bite column

- **High** — you *will* meet this; the triage tree and onboarding runbook exist
  precisely because these two (lending controller, Kueue admission) generate the
  most "is this broken?" moments, most of which are normal.
- **Medium** — capacity and observability: real but paced by fleet changes and
  scrape health, not daily.
- **Low** — rare or degraded-safe. The hub can be down and the platform keeps
  serving; that's KTD7 by design, not luck.

## The one thing to internalize

Almost every "incident" is the lending model working as designed — inference
holding the floor, a window closed, a wave draining. The
[Training not admitting](../runbooks/operations.md#training-not-admitting--normal-or-wedged)
triage tree is the reflex: **check normal before you page.** The genuinely
actionable failures are narrow: a wedged controller, a quota patch that won't
land, an undersized warm floor, or a dark evidence plane.
