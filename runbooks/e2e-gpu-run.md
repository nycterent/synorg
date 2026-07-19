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
- **Cheap mode (`E2E_CHEAP=1`): plan on ~$5-10 per full run** — 1-3
  g4dn.xlarge nodes (1× T4, spot ≈ $0.15-0.25/h each); the two EKS control
  planes and NAT dominate the bill. Scope caveats and mechanism: the
  [Cheap mode](#cheap-mode-e2e_cheap1--g4dnxlarge-spot-sizing-overlay)
  section below.
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

**Cheap-mode ask:** a cheap run (`E2E_CHEAP=1`) needs only **≥ 16 vCPUs** on
`L-3819A6DF` — g4dn.xlarge is 4 vCPU, so two lendable spot nodes are 8 vCPUs
plus headroom. `--check` under `E2E_CHEAP=1` validates against 16 instead of
48. File whichever ask matches the run you booked (both, if the full-size run
follows the cheap shakeout):

```bash
aws service-quotas request-service-quota-increase --region "$AWS_REGION" \
  --service-code ec2 --quota-code L-3819A6DF --desired-value 16   # cheap mode only
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
`clusters/mgmt/appsets/observability.yaml` (the dcgm-exporter ApplicationSet values), the DCGM ServiceMonitor
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
but are unattributable. In the kube-prometheus-stack values (same ApplicationSet file):

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

After the platform converges, `--up` installs the **e2e stand-ins**
(`tests/e2e/stand-ins/`, see each manifest's header): the inference render
path (golden-service release `inference` in ns `pilot`, stub image from the
run's ECR), the lendable-hold balloon that seeds the otherwise-empty lendable
pool, a statically-bound checkpoint PV, and the Service/PodMonitors for the
stand-in metric emitters. The canonical service images
(`ghcr.io/nycterent/synorg/<team>/...`) do not exist yet — without the stand-ins the lend
physics cannot start and the evidence plane has no emitters.

## Step 9 — Verify before testing

Per `runbooks/game-day.md` preconditions: evidence plane answering
(`render_start_seconds:p95` resolves), lending controller running and reading
the schedule, no unrelated reclaim phase in force. An unmeasured run has no
verdict — abort here rather than discover it mid-assertion.

## Step 10 — Physics + game-day assertions: `make e2e ARGS=--test`

```bash
make e2e ARGS=--test
```

Runs `tests/e2e/assertions.sh` in order: **lend** (taints + borrow pod, and a
snapshot of every lendable-pool instance-id at lend time) →
**reclaim-ahead-of-ramp** — the live schedule is driven onto a compressed
timeline: window opens now, reclaim waves at **+5/+8/+11 min**
(`E2E_WAVE_OFFSETS`), production ramp deadline at **+15 min**
(`E2E_RAMP_MINUTES`), window close at **+20 min** (`E2E_CLOSE_MINUTES`). The
close deliberately lands AFTER the ramp deadline: since the close path also
reclaims, a close inside the window could bail out a dead wave schedule —
with this ordering only the staged waves can clear lent taints before the
deadline, and the assertion additionally requires the controller's own
wave-firing (`action=reclaim_wave … reclaiming=`) and wave NodeClaim-deletion
(`action=nodeclaim_deleted … wave=`) log lines as positive evidence
(unreachable controller logs are a FAIL, not a skip) → **scrub** (nodeclaim
deleted; a Ready replacement whose instance-id is OUTSIDE the lend-time
snapshot — a pre-existing sibling never satisfies it; old vs new recorded) →
**rejoin under the render-start p95 gate** → **game-day storm scenarios**
(passGates from `rehearsal/scenarios.yaml`, `repeatRuns` times — a single
green run is not a pass) → **ledger zero-net-release**. Every assertion prints
PASS/FAIL; empty metrics are failures, never skips. The driven window closing
at +20 min adds no material runtime — the reclaim verdict lands before the
+15 min deadline and the schedule is restored during cleanup.

## Step 11 — Teardown: `make e2e ARGS=--down`

```bash
make e2e ARGS=--down
```

First terminates every Karpenter-provisioned pilot node (matched by the
`kubernetes.io/cluster/<pilot>` ownership tag AND a `karpenter.sh/nodepool`
tag) — Karpenter nodes are not terraform-managed, and their ENIs otherwise
pin the disposable VPC's subnets until the destroy times out. Then destroys
checkpoint-store → pilot → mgmt in reverse order. The ODCR capture is
**never destroyed here** — releasing held capacity is irreversible and
human-gated (`runbooks/capacity-carve.md`); returning fleet slots to the
reservation is exactly what keeps the ledger totals constant. If the VPC
destroy still reports `DependencyViolation`, check for EKS-created security
groups (`eks-cluster-sg-*`) that outlive the cluster: revoke their rules,
delete them, re-run `--down` — and verify absence with `describe-vpcs`
directly (a terraform "Destroy complete" with an empty state is not proof). (The full-cycle
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

## Cheap mode (`E2E_CHEAP=1`) — g4dn.xlarge spot sizing overlay

An env-gated overlay (`tests/e2e/cheap-overlay/apply.sh`, wired into
`tests/e2e/run.sh`; **default OFF**) that runs the same e2e on 1-GPU
g4dn.xlarge nodes for ~$5-10 instead of $30-80. The checked-in production
manifests (the pinned p5/g6e instance lists, pool sizes, quotas, ODCR counts)
are **never edited** — the overlay transforms the *live* objects after the
deploy converges, and dies with the teardown. Export `E2E_CHEAP=1` for
**every** phase (`--check`, `--up`, `--test`, `--down`); every phase prints an
unmissable `CHEAP MODE` banner so a cheap run can never be mistaken for the
production-profile proof.

**Cheap mode intentionally exercises the same physics with 1-GPU nodes**: the
lent-taint flips, staged reclaim waves, NodeClaim-delete scrub with a
new-instance-id proof, balloon preemption, borrowingLimit curve, and the
zero-net-release ledger all run the identical code paths — only the node size
and counts shrink.

**Region + capacity variants:** the synthetic e2e has no data-residency
constraint — regions are interchangeable for this test. Where the spot G/VT
quota is 0 (e.g. us-east-1, on-demand G/VT quota 504), run the pure on-demand
path: `AWS_REGION=us-east-1 E2E_CHEAP=1 E2E_CHEAP_CAPACITY=on-demand
E2E_VPC=create tests/e2e/run.sh` — the lendable pool becomes `on-demand`-only
(warm-floor keeps `reserved`), and `--check` hints against the on-demand quota
(`L-DB2E81BA`) instead of spot (`L-3819A6DF`). On-demand g4dn.xlarge is
~$0.53/hr/node — a full run stays single-digit dollars. `E2E_VPC=create`
stands up a disposable throwaway VPC (`tests/e2e/vpc/`: two public subnets
across two AZs, no NAT gateway — zero standing NAT cost, nodes get public IPs
with SG-restricted access) before the cluster modules and destroys it last, so
the run owns its network end-to-end instead of requiring an operator-provided
`TF_VAR_vpc_id`/`TF_VAR_subnet_ids`.

What the overlay resizes (one coherent set — the hand-synced cross-file
invariants from `docs/residual-review-findings/feat-eks-gpu-platform.md`,
re-asserted by the script's `COHERENCE` output on every render/apply):

| Surface | Production (committed) | Cheap (live overlay) |
|---|---|---|
| NodePool instance types (both GPU pools) | `p5.48xlarge`, `g6e.12xlarge` | `g4dn.xlarge` (1× T4) |
| `gpu-lendable` capacity types | `reserved`, `on-demand` | `spot`, `on-demand` (**test-only spot**) |
| `gpu-lendable` GPU limit | 64 | 2 (= 2 nodes × 1 GPU) |
| `gpu-warm-floor` GPU limit | 32 | 1 (= 1 node × 1 GPU) |
| `warm-floor-balloon` replicas | 4 | 1 (× 1 GPU/pod = floor GPU count) |
| Kueue `platform-lendable` nominalQuota | 64 | 2 |
| Kueue `training-borrow` borrowingLimit | 64 | 2 |
| ODCR `held_reservations` | 4× p5 + 8× g6e + 3× g7e | 1× g4dn.xlarge (`held.tfvars`) |

The lending schedule needs **no** overlay: `gpuLimitPct` is a percentage the
controller multiplies against *live* lendable capacity at tick time
(`controllers/lending/reconcile.sh reconcile_borrow_limit`), so the curve
scales down automatically; no absolute GPU count appears in the schedule.

**Mechanism (why live patches stick — ArgoCD):** `clusters/pilot/*` converges
via the `regions` ApplicationSet with `selfHeal: true`, which reverts bare
kubectl patches; and the ApplicationSet controller owns the generated
Application specs, so patching an Application alone does not stick either. The
ApplicationSets themselves are unmanaged (nothing reconciles
`clusters/mgmt/appsets/`), so the overlay patches the **ApplicationSet**
(`ignoreApplicationDifferences` on `/spec/syncPolicy`), drops `automated` sync
from exactly `pilot-karpenter` and `pilot-kueue`, then resizes the live
objects — sticky for the run, scoped to the sizing surface, and destroyed with
the clusters at `--down`. If the ApplicationSets were never bootstrapped, the
detach is skipped (nothing reconciles those objects, so direct patches hold).
The only host-side artifact is `infra/terraform/regions/pilot/odcr/held.tfvars`
(marker-tagged), which `--down` removes.

**Cheap-mode ODCR (read before `--up`):**

- Pre-apply the 1× g4dn capture from the same tfvars the overlay writes
  (`tests/e2e/cheap-overlay/apply.sh write-tfvars`, then
  `terraform -chdir=infra/terraform/regions/pilot/odcr apply -var-file=held.tfvars`,
  human-gated as always) — `--up` needs a no-changes ODCR plan to proceed
  non-interactively, exactly like the production runsheet Step 1.
- **A held ODCR bills like a running instance from the moment it exists** —
  create it right before the run and keep the carve window short. g4dn.xlarge
  on-demand ≈ $0.5-0.7/h; hours, not days.
- Teardown never destroys the ODCR (same human-gated rule as production), so
  **release the cheap reservation deliberately after the run** per
  `runbooks/capacity-carve.md` — it keeps billing until you do.
- **Sandbox account only:** the cheap tfvars replaces the whole
  `held_reservations` map. In an account whose state holds the production
  reservations, terraform would plan their destroy and `prevent_destroy`
  hard-errors — that guard firing means you pointed cheap mode at the wrong
  account. Use an account whose ODCR state was created from the cheap tfvars.

**What a cheap run does NOT prove** (honest scope — rerun full-size for
these):

- **Multi-GPU-per-node behavior**: per-GPU bin-packing, partial-node borrow,
  balloon-holds-one-of-8-GPUs semantics, NVLink/VRAM-scrub nuance on 8-GPU
  hosts — every node here has exactly one GPU.
- **p5/g6e-class capacity dynamics**: real ODCR contention, reserved-capacity
  fallback under scarcity, p5 launch latencies and interruption behavior.
- **Production quota/scale envelopes**: the 48+ vCPU spot footprint, multi-AZ
  spread, consolidation pressure at fleet size.
- The **spot lendable pool is a test-only liberty** — production lendable is
  `reserved`/`on-demand`; spot interruptions during a cheap run are noise the
  production profile does not have.

Cheap mode also retunes two assertion knobs (both env-overridable, both
announced loudly in the run log): `E2E_PEAK_RPS` defaults to 100 (the
single-replica render stand-in is a stub, not a GPU fleet — 4000 RPS would
only benchmark the stub) and `E2E_SHARED_STORE_MIN_MBPS` defaults to 50 (the
checkpoint stand-in writes node-local disk, so the 2000 MBps shared-store
floor is not a meaningful gate on this stack; the gate still proves writes
happen and are measured).

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
