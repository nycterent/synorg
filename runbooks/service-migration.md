# Runbook: service migration (ECS → EKS, strangler behind the shared ALB)

Move one service from ECS to the golden chart with no big-bang cutover. Traffic
shifts by ALB target-group weight, and rollback is a weight flip. This runbook is
the **single migration playbook** (KTD11 strangler): U13 proves it on GPU
inference; U14 reuses it **unchanged** for the web fleet. If a web migration
needs the steps to diverge, the playbook was wrong — fix it here, do not fork it.

**Scope:** one service, one PR-driven progression. GPU-specific notes are called
out; everything else is class-agnostic.

**Roles:** the migrating team owns the service; platform owns the ALB weight
changes and the game-day gate.

## Preconditions

- Target cluster is at converged state and its game-day gate has passed (U10).
- For GPU inference: held capacity for this service's instances is already
  captured in an ODCR and the carve increment is reserved (U15,
  `runbooks/capacity-carve.md`) — you never terminate an ECS instance before the
  reservation demonstrably holds its capacity.
- The service still serves 100% from its ECS target group.

## Steps

### 1. Capture the ECS baseline

Record the service's **p95 latency** and **error rate** from current ECS
production traffic, over a window that includes a representative peak. For
inference, the window **must include a morning reclaim** (the render-path
pressure event) — that is the parity bar the migration is judged against.

Store the baseline with the migration PR so parity is checked against a pinned
number, not a moving one.

### 2. Bridge-translate the env-spec (once)

```bash
python3 tools/env-spec-bridge/bridge.py services/<service>.envspec.yaml \
  -o clusters/<region>/services/<service>.yaml    # web: clusters/<region>/web/<service>.yaml
```

The translation is mechanical and deterministic (Success Criterion 5). If the
bridge errors, it names the offending key — fix the env-spec or move the concept
to its platform home (e.g. env vars → ESO), do not hand-edit around it.

### 3. Review once, then own as values

Review the generated values **one time** as a normal PR. After merge the service
is owned as golden values; the env-spec is scheduled for deletion
(`docs/env-spec-retirement.md`). No further bridge runs for this service.

### 4. Deploy to EKS (0% traffic)

Merge the values file. GitOps converges the Deployment/Service on the target
cluster with **no** ALB weight yet — the workload is running and healthy but
takes no production traffic. Confirm it reaches ready and its probes pass.

Validation gate: `make validate` is green (helm template → kubeconform →
kyverno test → rendered diff). A namespace-scoped non-prod change auto-merges
(autonomous tier, `docs/capability-tiers.md`).

### 5. Shadow / weighted shift

Shift ALB target-group weight from the ECS group to the EKS group in increments
(e.g. shadow or 5% → 25% → 50% → 100%). Hold at each step long enough to observe.

For GPU inference: advance a weight step only while the corresponding carve
increment shows its reservation holding capacity — capacity moves in lockstep
with traffic, never ahead of it.

### 6. Parity check at each step

At every weight step, compare EKS **p95 latency** and **error rate** against the
ECS baseline from step 1. For inference, parity must hold **through a morning
reclaim** at that weight before advancing. If parity fails, **do not advance** —
go to Rollback.

### 7. Cut to 100% and soak

At 100% EKS, soak for a **full week including morning reclaims** with
baseline-parity metrics (U13 verification bar) before the service is considered
converted. On conversion, fill its row in `docs/env-spec-retirement.md` and
delete its env-spec.

## Rollback (= weight flip)

Rollback is flipping the ALB weight back toward the ECS target group — no
redeploy, no data migration. Because ECS keeps running until conversion is
proven, the ECS path is always warm.

- Trigger: any failed parity check (step 6), or an error-rate/p95 regression at
  100%.
- Action: set the EKS weight to 0 (or the last known-good step). Traffic returns
  to ECS immediately.
- GPU: rolling back weight does **not** release the carve — held capacity stays
  reserved; only traffic moves.
- Rehearse the full-weight rollback **once** per fleet before relying on it (U13
  rehearses on the pilot; U14 rehearses on the first web wave).

## After all services convert

When the last service on ECS converts, ECS is emptied and deleted and the bridge
tool is removed — see `docs/ecs-retirement.md`.
