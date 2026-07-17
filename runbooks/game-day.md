# Runbook: preemption game-day (U10)

Executable procedure for one game-day run against the **pilot cluster**. Rehearses
the morning-ramp preemption storm and decides the R2 pass/fail that gates Phase
2→3 (U12). Run one scenario per invocation from `rehearsal/scenarios.yaml`; repeat
`repeatRuns` times before calling a verdict (a single green run is not a pass).

**Never run on the auto lane and never against a region carrying real traffic** —
this drives real preemption. Pilot cluster only.

## Variables

```bash
export SCENARIO=staged-reclaim-normal      # one of scenarios.yaml .scenarios[].name
export KUBECONFIG=~/.kube/pilot            # pilot cluster only
export PROM='http://prometheus.observability.svc:9090'   # in-cluster read-API
```

## Preconditions (abort if any fails)

- Pilot cluster + Karpenter live (U3); warm floor at its configured size.
- Lending controller running and reading the schedule (U8); it is the only thing
  that flips lent taints and drives reclaim.
- Evidence plane up (U9): `render_start_seconds:p95` and the passGate series
  resolve in Prometheus **right now** (query them once — empty result ⇒ abort,
  you cannot judge a run you cannot measure).
- No unrelated reclaim window currently open (check the schedule clock).

```bash
# Confirm the read-API answers before starting.
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=render_start_seconds:p95' \
  | jq -e '.data.result | length > 0' || { echo "evidence plane not answering — ABORT"; exit 1; }
```

## Step 1 — Apply the harness and select the scenario

```bash
kubectl apply -f rehearsal/scenarios.yaml -f rehearsal/loadgen.yaml
# Wire loadgen env from the scenario's loadProfile (PEAK_RPS, RAMP_MINUTES,
# TARGET_URL). CI templates this; manually:
kubectl -n rehearsal set env deploy/game-day-loadgen \
  PEAK_RPS=4000 RAMP_MINUTES=90 TARGET_URL="http://inference.pilot.svc.cluster.local/render"
```

## Step 2 — Saturate training on the lent nodes

Fill every lent GPU so the reclaim has real work to preempt (the whole point —
an empty reclaim proves nothing). Submit training to the `training-borrow` queue
up to full borrow.

```bash
# Submit the game-day training workload (checkpointing every 5 min per KTD12) to
# saturate borrow. Confirm lent nodes are busy before load starts.
kubectl get nodes -l 'lending.synorg.io/lent=true' -o name   # must be non-empty
```

## Step 3 — Start inference load

```bash
kubectl -n rehearsal scale deploy/game-day-loadgen --replicas=1
# For ramp scenarios, load climbs over RAMP_MINUTES; for storm, it steps to peak.
```

## Step 4 — Drive the reclaim shape

Match the scenario's `reclaim` field:

- `from-schedule` (staged-reclaim-normal): let the controller run its scheduled
  waves. Do nothing but watch.
- `override: compressed` / `all-at-once`: trigger the compressed/simultaneous
  reclaim per the scenario (harness signals the controller's rehearsal hook).
- `faultInjection` (driver-wedge): at `atMinuteIntoReclaim`, inject a DCGM XID
  fault on one reclaiming node; confirm `gpu-node-quarantine.md` fires (node
  fenced, `NodeQuarantined` event) and is **not** returned to prod.

Watch the lifecycle events (U8 emit-events contract):

```bash
kubectl get events -A --field-selector reason=ReclaimWaveStarted -w
```

## Step 5 — Collect evidence (from slo-definitions.yaml queries)

Query the pass-gate series over the run window. These are the SAME series the
read-API exposes, so the verdict is reproducible.

```bash
Q() { curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result'; }

# Render floor during reclaim (target <= renderStartP95TargetSeconds):
Q 'render_start_seconds:p95:reclaim_window'
# Training lost work (target <= trainingLostWorkMaxSeconds = 300):
Q 'max(training_checkpoint_lost_seconds)'
# Shared checkpoint store throughput while ALL lent nodes checkpoint at once
# (target >= sharedStoreMinThroughputMBps):
Q 'min(checkpoint_store_write_throughput_mbps)'
```

Record every value with its timestamp. Repeat Steps 3–5 for `repeatRuns` runs.

## Step 6 — Pass/fail decision

Evaluate the scenario's `passGates` (scenarios.yaml) against the collected series:

- **PASS** — all gates hold across every repeat run AND cross-run p95 spread <
  `renderStartP95VarianceMaxSeconds`. Only then is the scenario green.
- **FAIL** — any gate breached, or variance too high to distinguish a regression
  from noise.

## Step 7 — On fail: warm-floor-resize-first (Assumption 5)

The first remediation is **always** to raise the warm floor, never to tighten the
training grace:

```bash
# Raise the floor: bump the balloon replicas and the gpu-warm-floor NodePool GPU
# limit (a PR to those files — git is the write path). Re-run the scenario.
#   clusters/pilot/karpenter/warm-floor-balloon.yaml       (replicas)
#   clusters/pilot/karpenter/nodepool-gpu-warm-floor.yaml  (limits.nvidia.com/gpu)
```

Only if a resized floor still fails do you revisit wave timing / lending-window
length. Tightening the 120 s grace below KTD12 is the last resort — it destroys
training work and does not fix a render breach.

## Step 8 — Report and tear down

Write the signed-off game-day report into the repo (per-scenario, per-run metric
tables + the verdict). A PASS report is the Phase 2→3 gate evidence and a
precondition for U12; a FAIL blocks it.

```bash
kubectl -n rehearsal scale deploy/game-day-loadgen --replicas=0
kubectl delete -f rehearsal/loadgen.yaml
# Stop the game-day training workload; let the schedule return to normal.
```

## Abort / invariant semantics

- No measurable evidence plane (Step precondition) → abort; an unmeasured run has
  no verdict.
- A quarantined node in the driver-wedge scenario must never return to prod
  within the run — that is a scenario failure, not a warning.
- One scenario per invocation; never batch, so a failure attributes to one
  reclaim shape.
