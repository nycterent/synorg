# Runbook: GPU node quarantine (DCGM failure)

Executable playbook for isolating a GPU node that fails a health check, diagnosing
it, and routing it to the scrub path. GPU node auto-repair in Karpenter is alpha
and currently unreliable (kubernetes-sigs/karpenter#2833) — **we do not enable it**.
Node health remediation is this runbook, driven by DCGM signal, not an assumed
controller feature (KTD9 caveat).

A quarantined node is fenced off (`Quarantined` state) so no inference or training
lands on suspect hardware, then either recovered by scrub (fresh instance) or, if
the fault is capacity-level, escalated. **A quarantined node never returns to prod
without completing the verify steps below.**

Preconditions: DCGM exporter is running (U9 `observability`), and an alert or the
lending-controller has flagged a health failure on the node.

## Variables

```bash
export NODE=ip-10-0-0-0.eu-west-1.compute.internal   # the suspect GPU node
export REGION=eu-west-1
```

## Step 1 — Quarantine: taint and cordon immediately

Fence the node before diagnosing so nothing new schedules onto suspect hardware.
The controller emits `NodeQuarantined` (consumed by U9).

```bash
# Quarantine taint keeps ALL workloads off (inference and training both).
kubectl taint node "$NODE" gpu.synorg.io/quarantine=true:NoSchedule --overwrite
kubectl cordon "$NODE"
# Evict running GPU work with grace so training final-checkpoints (KTD12: 120 s).
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data \
  --grace-period=120 --skip-wait-for-delete-timeout=120
```

## Step 2 — Diagnose (record the fault before discarding it)

Capture the DCGM signal so the fault is attributable (transient XID vs persistent
ECC vs board-level) — this is the evidence that decides recover-vs-escalate.

```bash
# 2a. DCGM health + XID/ECC counters for this node (see U9 recording rules).
#     Query dcgm_gpu_health, DCGM_FI_DEV_XID_ERRORS, DCGM_FI_DEV_ECC_* for $NODE.
kubectl get pods -n observability -l app=dcgm-exporter \
  --field-selector "spec.nodeName=$NODE" -o name

# 2b. Node-level kubelet/device-plugin view.
kubectl describe node "$NODE" | sed -n '/Conditions:/,/Events:/p'

# 2c. Record: XID number(s), whether ECC is correctable/uncorrectable, and
#     whether the fault clears on read. Attach to the incident.
```

Decision:
- **Transient / correctable** (single XID, clears, correctable ECC) → recover by
  scrub (Step 3): a fresh instance almost always clears it.
- **Persistent / uncorrectable** (repeating XID 48/63/79, uncorrectable ECC,
  board fell off the bus) → escalate (Step 4); do not just cycle instances on
  bad silicon.

## Step 3 — Recover via scrub (fresh instance)

For transient faults, quarantine hands off to the scrub path. The scrub deletes
the NodeClaim and Karpenter recovers a fresh instance — same discard-and-recover
boundary as a normal return.

```bash
# Follow runbooks/node-scrub.md from Step 2 (delete nodeclaim) onward.
# Its Step 4b DCGM-clean check IS the quarantine-clear gate: the fresh node must
# report clean health before any untaint.
```

After scrub verification passes, remove the quarantine taint (the scrub already
returns a *new* node, so this clears the fence on the replacement):

```bash
kubectl taint node "$NEW_NODE" gpu.synorg.io/quarantine- 2>/dev/null || true
```

## Step 4 — Escalate (persistent hardware fault)

If diagnosis says the silicon is bad, cycling instances just re-lands the fault
(a reserved slot may map to the same physical board). Leave the node quarantined,
open a hardware incident, and — if the fault is capacity-level — record a scarcity
signal (U9 asked/got series) so fleet shaping sees the lost capacity.

```bash
# Keep the fence; do NOT return to prod.
# Open incident with the Step 2 evidence. If a reserved slot is unhealthy,
# raise it against the ODCR (infra/terraform/regions/pilot/odcr) so the held
# count reflects reality.
```

## Abort / invariant semantics

- A quarantined node **never** returns to prod without a clean DCGM verify
  (node-scrub.md Step 4b). No exceptions for "it looked fine after a reboot" —
  in-place reboot is not a trust reset.
- Persistent/uncorrectable faults are escalated, not scrub-looped. Recovering a
  bad board by reprovisioning wastes reclaim time and risks silent corruption.
- Every quarantine and clear emits an Event (`NodeQuarantined` / `NodeScrubbed`)
  so the evidence plane has the full timeline.
