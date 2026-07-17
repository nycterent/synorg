# Runbook: e2e GPU run (U7)

Execution runsheet for one full e2e run: deploy a spot-GPU pilot, prove the
lend/reclaim/scrub/preemption physics plus the game-day gate on real hardware,
tear down. The driver is `tests/e2e/run.sh` (`make e2e`); this runsheet is the
ordered procedure around it, with the gotchas that sink first runs — spot
quota, the Karpenter ReservedCapacity feature gate, the DCGM relabel, the
kube-state-metrics pod-label allowlist, the balloon floor — as first-class
steps, not footnotes.

**This spends real money and touches real capacity.** Never point it at a
region carrying real traffic, and never at an account whose held reservations
you are not allowed to rehearse against. The zero-net-capacity-release
invariant (`runbooks/capacity-carve.md`) is snapshotted at entry and asserted
at exit — a drifted ledger is a hard stop.

## Variables

```bash
export AWS_REGION=eu-west-1                # pilot region (workflow input `region`)
export PILOT_CONTEXT=synorg-pilot          # kubeconfig aliases, as scripts/deploy.sh
export MGMT_CONTEXT=synorg-mgmt
export E2E_STATE_DIR=build/e2e             # snapshots + logs (CI uploads this)
# export E2E_PROM=http://...:9090          # optional: Prometheus read-API override.
#                                          # Unset (default): the assertions discover
#                                          # any :9090 Service in the observability
#                                          # namespace (E2E_PROM_NAMESPACE overrides),
#                                          # falling back to prometheus-operated;
#                                          # none found is a loud FAIL, not a skip.
```

## Step 0 — Read the source runbooks first (abort-level prerequisite)

Do not run anything until you have read, in this order:

1. `runbooks/game-day.md` — the scenario mechanics, evidence queries, and the
   "an unmeasured run has no verdict" abort rule this tier inherits.
2. `runbooks/node-scrub.md` — why the scrub assertion demands a NEW EC2
   instance-id (equal id ⇒ VRAM not reset ⇒ abort).
3. `runbooks/capacity-carve.md` — the zero-net-release ledger semantics the
   run is bracketed by.
4. `rehearsal/scenarios.yaml` — the storm scenarios and passGate thresholds
   the game-day assertion evaluates verbatim.

## Step 1 — Pre-flight: account, region, cost, time budget

- A dedicated AWS account (or a sandbox you may rehearse in), with the ODCR
  capture (`infra/terraform/regions/pilot/odcr`) already applied — the ODCR
  module is never `-auto-approve`d, so a pre-existing capture (terraform "no
  changes") is what lets the non-interactive `--up` proceed.
- **Cost estimate:** budget for 2× EKS clusters (~$0.20/h) + 2-4 spot GPU
  nodes (g6.12xlarge spot ≈ $1.5-2.5/h each, region-dependent) + NAT/EBS/S3
  for ~half a day: plan on **$30-80 per full run**. Review actual spend after
  teardown (post-run checklist).
- **Time budget:** ~45 min deploy, ~60-90 min physics + game-day (repeatRuns
  multiplies), ~20 min teardown. Block **3-4 hours**; do not start a run you
  cannot finish — a half-done run left up burns GPU-hours.

## Step 2 — Request spot GPU quota AHEAD of the run (days of lead time)

g5/g6 spot capacity draws from the EC2 vCPU quota **"All G and VT Spot
Instance Requests" — quota code `L-3819A6DF`** (service `ec2`). New accounts
often sit at 0; increases can take days, so file this before booking the run.
The on-demand counterpart (**`L-DB2E81BA`**, "Running On-Demand G and VT
instances") matters too: it is where the ReservedCapacity/ODCR fallback path
lands (Step 3).

```bash
aws service-quotas get-service-quota --region "$AWS_REGION" \
  --service-code ec2 --quota-code L-3819A6DF --query 'Quota.Value'
# Require: >= 48 vCPUs (one g6.12xlarge + headroom). If lower:
aws service-quotas request-service-quota-increase --region "$AWS_REGION" \
  --service-code ec2 --quota-code L-3819A6DF --desired-value 96
```

`make e2e ARGS=--check` (Step 7) re-reads both quotas and hints, but it only
describes — the increase request is this step, done ahead.

## Step 3 — Enable the Karpenter ReservedCapacity feature gate

Without the **ReservedCapacity** feature gate, Karpenter ignores
`capacityReservationSelectorTerms` and the NodePools **silently fall back to
on-demand** — the run "works" but proves nothing about the held-capacity path
and double-pays for the fleet. Set it where the pilot's Karpenter is
configured (`infra/terraform/regions/pilot` Karpenter helm values /
`clusters/pilot/karpenter/`):

```yaml
# Karpenter controller settings (helm values):
settings:
  featureGates:
    reservedCapacity: true
```

Verify before proceeding — the gate must be visible in the running controller:

```bash
kubectl --context "$PILOT_CONTEXT" -n kube-system get deploy karpenter \
  -o yaml | grep -i reservedcapacity
# Empty output ⇒ the gate is OFF ⇒ fix it now; do not run the physics on a
# fleet that quietly fell back to on-demand.
```

## Step 4 — DCGM exporter relabel for the node label

The scrub and attribution evidence joins DCGM GPU series to Node objects by
node name. The DCGM exporter's ServiceMonitor must **relabel the exporter's
instance/pod labels onto the `node` label**, or every per-node PromQL join in
the assertions returns empty (which is a FAIL, not a skip). In
`clusters/pilot/observability/prometheus-stack.yaml`, the DCGM ServiceMonitor
needs:

```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_pod_node_name]
    targetLabel: node
    action: replace
```

Verify: `DCGM_FI_DEV_GPU_UTIL` carries a `node` label matching
`kubectl get nodes` names.

## Step 5 — kube-state-metrics pod-label allowlist for attribution

Per-team GPU-hour attribution joins pod labels × node lifecycle. KSM drops
pod labels unless allowlisted — without this, the attribution series exist
but are unattributable. In the kube-prometheus-stack values:

```yaml
kube-state-metrics:
  metricLabelsAllowlist:
    - pods=[team.synorg.io/name,team.synorg.io/class]
```

Verify: `kube_pod_labels{label_team_synorg_io_name!=""}` returns series.

## Step 6 — Confirm the balloon floor schedules

The warm-floor balloon is what makes reclaim non-destructive to the render
path. If the balloon pods are Pending, the floor does not exist and the p95
gate will (correctly) fail for the wrong reason:

```bash
kubectl --context "$PILOT_CONTEXT" -n platform-system rollout status \
  deploy/warm-floor-balloon --timeout=300s
# Pending balloons ⇒ fix the floor first (nodepool-gpu-warm-floor limits,
# runbooks/game-day.md Step 7 semantics) before any assertion run.
```

## Step 7 — Pre-flight gate: `make e2e ARGS=--check`

```bash
make e2e ARGS=--check
```

Refuses (rc != 0) without AWS credentials; with them it verifies the
toolchain and re-reads the Step 2 quotas (describe-only). Fix every hint
before continuing.

## Step 8 — Deploy: `make e2e ARGS=--up`

```bash
make e2e ARGS=--up          # scripts/deploy.sh --auto-approve, runbook order
```

Runs the full `runbooks/deploy-platform.md` order (ODCR → mgmt+ArgoCD →
pilot+checkpoint-store → spoke → policy → scheduling → evidence) and waits for
Ready nodes + the balloon floor. The zero-net-release guard runs inside the
deploy after every capacity-touching step.

## Step 9 — Verify before testing

Per `runbooks/game-day.md` preconditions: evidence plane answering
(`render_start_seconds:p95` resolves), lending controller running and reading
the schedule, no unrelated reclaim window open. An unmeasured run has no
verdict — abort here rather than discover it mid-assertion.

## Step 10 — Physics + game-day assertions: `make e2e ARGS=--test`

```bash
make e2e ARGS=--test
```

Runs `tests/e2e/assertions.sh` in order: **lend** → **reclaim-ahead-of-ramp**
(driven schedule + synthetic inference ramp) → **scrub** (nodeclaim deleted,
replacement has a NEW instance-id; old vs new recorded) → **rejoin under the
render-start p95 gate** → **game-day storm scenarios** (passGates from
`rehearsal/scenarios.yaml`, `repeatRuns` times — a single green run is not a
pass) → **ledger zero-net-release**. Every assertion prints PASS/FAIL; empty
metrics are failures, never skips.

## Step 11 — Teardown: `make e2e ARGS=--down`

```bash
make e2e ARGS=--down
```

Destroys checkpoint-store → pilot → mgmt in reverse order. The ODCR capture is
**never destroyed here** — releasing held capacity is irreversible and
human-gated (`runbooks/capacity-carve.md`); returning fleet slots to the
reservation is exactly what keeps the ledger totals constant. (The full-cycle
`make e2e` runs Steps 8-11 in one go, teardown trap-guarded: a failed
assertion still tears down unless `E2E_KEEP=1`.)

CI (`.github/workflows/e2e.yaml`) runs `--check`, `--up`, `--test`, and
`--down` as **separate steps** rather than the single-process full cycle: a
cancelled or timed-out step gets only seconds of kill grace, so teardown lives
in its own `always()` step with its own timeout — cancellation cannot kill a
destroy mid-flight. The ledger entry snapshot is taken by `--up` and asserted
by `--down`, so the zero-net-release invariant spans the whole job. The only
teardown skip is the `keep-on-failure` input when the test step failed.

## Step 12 — Post-run checklist

- [ ] **Zero net release verified** — the run ended with
      `PASS: ledger unchanged`; the entry/exit snapshots are in
      `$E2E_STATE_DIR/ledger-{entry,exit}.txt`. Any diff → follow
      `capacity-carve.md` abort semantics immediately.
- [ ] **Cost reviewed** — Cost Explorer for the run window against the Step 1
      estimate; unexplained spend usually means something survived teardown
      (`aws ec2 describe-instances --filters Name=instance-state-name,Values=running`).
- [ ] Schedule ConfigMap restored to the git-controlled original (the
      assertions restore it; verify — git is the only durable write path, KTD5).
- [ ] Game-day report recorded per `runbooks/game-day.md` Step 8 (per-scenario,
      per-run tables + verdict) — this is the Phase 2→3 gate evidence.
- [ ] Logs/artifacts archived: `$E2E_STATE_DIR/` (CI uploads it automatically).

## Abort / invariant semantics

- No credentials, missing quota, or an unanswering evidence plane → abort
  before `--up`; nothing is deployed on a run that cannot be measured or
  launched.
- Ledger drift at any point → hard stop, `capacity-carve.md` abort semantics;
  do not continue testing on an account that just released held capacity.
- Scrub returning an equal instance-id → the node never left; abort and treat
  as a controller defect (`node-scrub.md` abort case), not a flake.
- A run you cannot finish in the time budget → tear down (`--down`) rather
  than leave GPUs burning; a partial run with teardown is recoverable, an
  abandoned pilot is just cost.
