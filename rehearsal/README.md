# Preemption game-day harness (U10)

Synthetic rehearsal of the morning-ramp preemption storm against the **pilot
cluster**. It proves R2 — render-start p95 holds through reclaim AND training
loses ≤5 min of work under concurrent checkpointing — before real traffic depends
on it. This is the **Phase 2→3 gate**: a signed-off pass here is a precondition
for the multi-region rollout (U12).

This directory is *not* auto-deployed by the fleet ApplicationSet (that globs
`clusters/<name>/*`, not `rehearsal/`). It is applied on demand by the CI
game-day job against the pilot cluster and torn down after.

## Contents

- `scenarios.yaml` — the four storm scenarios and their pass gates (parameterized
  thresholds). Source of truth for what "pass" means.
- `loadgen.yaml` — k6 render-path load generator (script ConfigMap + Deployment
  the harness scales 0↔1) plus the demand profile.
- `../runbooks/game-day.md` — the executable procedure: preconditions, run a
  scenario, collect evidence, decide pass/fail.

## Scenarios

| Scenario | Reclaim shape | What it stresses |
|---|---|---|
| `staged-reclaim-normal` | the scheduled 05:30/06:00/06:30 waves | the happy path holds the SLO |
| `compressed-reclaim` | all waves in a 20-min window | late ops don't breach R2 |
| `storm-all-at-once` | every lent node at once | warm floor alone holds render |
| `driver-wedge-during-reclaim` | fault injected mid-wave | quarantine fires without breaching R2 |

## Running from CI

The game-day job is manual/on-demand (never on the auto lane — it drives real
preemption on the pilot cluster). Outline:

```bash
# 1. Apply the harness to the pilot cluster.
kubectl apply -f rehearsal/namespace.yaml -f rehearsal/scenarios.yaml -f rehearsal/loadgen.yaml

# 2. Pick a scenario and wire the loadgen env from its loadProfile.
SCENARIO=staged-reclaim-normal
#    (CI reads scenarios.yaml, sets TARGET_URL/PEAK_RPS/RAMP_MINUTES on the
#     game-day-loadgen Deployment for $SCENARIO.)

# 3. Follow runbooks/game-day.md: start load (scale loadgen to 1), trigger the
#    reclaim shape, collect the passGate series, then stop load (scale to 0).

# 4. Evaluate passGates from scenarios.yaml against the collected series and
#    write the signed-off report into the repo.

# 5. Tear down.
kubectl delete -f rehearsal/loadgen.yaml
```

Pass gates are evaluated against the **same** recording-rule series the read-API
exposes (`slo-definitions.yaml`), so the harness verdict and the evidence plane
can never disagree on a number.

## Phase 2→3 gate semantics

- **Pass** = every scenario's pass gates hold across `repeatRuns` (default 3),
  AND cross-run variance stays under `renderStartP95VarianceMaxSeconds` — so a
  future regression is distinguishable from run-to-run noise.
- **Fail** = escalate per Assumption 5: **raise the warm floor first**
  (`replicas` on `warm-floor-balloon` and the `gpu-warm-floor` NodePool limit).
  Tightening the 120 s training grace is the last resort — it just destroys
  training work and does not fix a render breach.
- A pass unlocks U12; a fail blocks it. The signed-off report lives in-repo as the
  gate evidence.

## Repeat-run variance

Run each scenario `repeatRuns` times. Real clusters are noisy (cold caches, AZ
placement, background consolidation); a single green run is not a pass. The gate
is the *distribution*: median within target with spread under the variance bound.
Record all runs in the report, not just the best.
