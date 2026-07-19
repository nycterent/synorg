# Lending controller (U4 thin v0)

A deliberately thin, `kubectl`-driven reconcile loop that actuates the
git-controlled lending schedule. It replaces the placeholder image in
`clusters/pilot/lending/lending-controller.yaml` with something real and
deployable, so the lend/reclaim lifecycle runs unattended while the full
operator (plan-001 U8) is built. Same Deployment, same RBAC, same schedule —
only the image contents are v0.

## What it does each tick

Reads `SCHEDULE_FILE` (the mounted `lending-schedule` ConfigMap) fresh, then —
in this order; waves run **before** taint reconcile so a window closing at a
wave's `startsAt` (wave-3 `06:30` == `closesAt 06:30`, which `window_open`
reads as closed) still sees the lent taints the wave selection keys on:

1. **Reclaim waves** — a wave is due for `WAVE_FIRE_WINDOW_SECONDS` after its
   `startsAt`, and fires **at most once per scheduled occurrence**: a marker
   file (`KUBECTL_CACHE_DIR/fired-waves/<YYYY-MM-DD>-w<index>-<startsAt>`)
   records each firing and is pruned after 2 days. Keying on the occurrence
   (not just the day) matters for game-day rehearsals, which re-drive the
   same wave names onto new times several times a day — each re-drive must
   fire again. Markers live on the `/tmp` emptyDir, so
   they survive container restarts but not pod replacement — a replaced pod
   can allow one re-fire (accepted v0 caveat). Selection is
   `ceil(reclaimFraction x currently-lent)` where currently-lent **excludes
   already-cordoned nodes**, so even a re-fire can never re-count an
   in-flight reclaim. Per node (the shared `reclaim_node` path):
   - **EKS** (Karpenter API present): cordon, drain via the eviction API with
     `drainGraceSeconds`, then delete the node's NodeClaim — Karpenter
     terminates the instance, which *is* the scrub boundary (fresh instance,
     fresh AMI).
   - **kind** (no Karpenter API): logs `action=reclaim_intent` with the
     intended cordon+drain+nodeclaim-delete and does nothing. This is by
     construction: kind has no NodeClaims and the ClusterRole grants no
     `nodes: delete`.
2. **Window taints** — if a lending window is open (region-local time, DST via
   the schedule `timezone`), adds `targets.lentTaint` to every Node labeled
   `karpenter.sh/nodepool=<targets.lendablePool>`. On close, a still-lent
   node is **never bare-untainted** — the close transition is itself a
   reclaim, routed through the same `reclaim_node` path as the waves:
   - **EKS with a NodeClaim**: cordon+drain+NodeClaim delete; the Node object
     disappears with the instance, so no untaint is needed.
   - **EKS without a NodeClaim** (anomalous): cordon+drain, a loud
     `action=reclaim` warning that scrub-by-termination is unavailable, then
     untaint — the node is left cordoned for operator action.
   - **kind**: `action=reclaim_intent reason=window_close`, then untaint
     (documented degradation — matches the wave behavior on kind).
   Nodes a wave already cordoned are in-flight reclaims and are left alone.
   Idempotent: only actual transitions act and emit.
3. **Borrow curve** — resolves the active `borrowingLimitCurve` entry (the most
   recently passed `at`, daily recurrence), converts `gpuLimitPct` to an
   absolute quantity against the *current* summed `nvidia.com/gpu` capacity of
   lendable Nodes, and patches the `targets.trainingQueue` ClusterQueue
   `borrowingLimit`. Patches only on change.

A malformed or unsupported schedule (bad YAML, wrong `schemaVersion`, missing
required field, **any clock field that is not strict `HH:MM`** — window
`opensAt`/`closesAt`, every `reclaimWaves[].startsAt`, every
`borrowingLimitCurve[].at` — or an invalid `days[]` name) logs
`action=schedule_invalid` with the reason and **skips the whole tick before
any kubectl call** — malformed intent never reaches waves or taints, and the
actuator never crash-loops on it.

## Schedule schema consumed (contract)

`schemaVersion: 1` of `clusters/pilot/lending/schedule.yaml` (the authoritative,
commented copy). Fields read by v0:

| Field | Use |
|---|---|
| `schemaVersion` | must be `1`, else refuse to actuate |
| `timezone` | region-local clock for all times below |
| `targets.lendablePool` | Node selector `karpenter.sh/nodepool=<name>` |
| `targets.lentTaint` | `key=value:effect` flipped on Nodes |
| `targets.trainingQueue` | ClusterQueue whose `borrowingLimit` is patched |
| `windows[]` (`opensAt`, `closesAt`, `days`) | window state; wraps midnight |
| `borrowingLimitCurve[]` (`at`, `gpuLimitPct`) | borrow limit steps |
| `reclaimWaves[]` (`startsAt`, `reclaimFraction`, `drainGraceSeconds`) | staged reclaim |

Read but not yet actuated by v0 (real-operator scope): `productionRampAt`,
`nodeReturnToServiceBudgetSeconds`, `nightScrubRotation`,
`preferPreScrubbed` (v0 picks lent nodes in list order, no pre-scrub state).

## Write surface

**Node objects and the training ClusterQueue. Nothing else.** Never NodePool
templates — Karpenter drift-detects a `spec.template` change and answers with a
full-pool replacement at every window transition (the drift trap; see the
ClusterRole comment in `lending-controller.yaml` and plan-001 U8). Plus
Kubernetes Events (below) and, on EKS reclaim, NodeClaim deletes and pod
evictions via drain.

## Events / logs (evidence contract, plan-001 U8)

Every action emits a structured log line (`ts= level= action= ...`) and, with
`EMIT_EVENTS=true`, a Kubernetes Event in the `default` namespace bound to the
Node or ClusterQueue (both are cluster-scoped, and the API requires an Event
on a cluster-scoped object to live in `default`): `LendWindowOpened`, `NodeLent`, `NodeReturnedToProd`,
`BorrowLimitPatched`, `ReclaimWaveStarted`, `NodeDraining`, `NodeScrubStarted`.
The remaining state-machine reasons (`NodeScrubbed`, `NodeQuarantined`,
`ScrubRotated`) require scrub verification and DCGM health — real-operator
scope.

## RBAC envelope

The controller runs inside the RBAC already granted in
`clusters/pilot/lending/lending-controller.yaml` — v0 changed **no** RBAC:

- `nodes`: get/list/watch/patch/update (taint, cordon)
- `karpenter.sh nodeclaims`: get/list/watch/delete (reclaim scrub)
- `kueue.x-k8s.io clusterqueues`: get/list/watch/patch/update (borrow curve)
- `events` (core + events.k8s.io): create/patch
- `pods`: get/list/watch and `pods/eviction`: create (drain)
- namespaced: `configmaps` read, `leases` (reserved for the real operator's
  leader election; v0 relies on `replicas: 1` + `Recreate`)

`test.sh` enforces this offline: it parses every `kc` invocation in
`reconcile.sh`, maps it to `(apiGroup, resource, verb)` tuples, and asserts the
set is a subset of what the Role grants. Every kubectl call must go through the
single-line `kc <subcommand> <resource> ...` wrapper so the parser fails closed.

## kind vs EKS

| Behavior | kind (U1 harness) | EKS |
|---|---|---|
| Window taints | real | real |
| borrowingLimit patch | real (fake-GPU capacity) | real |
| Reclaim wave | `reclaim_intent` log only | cordon + drain + NodeClaim delete |
| Window close (still-lent node) | `reclaim_intent reason=window_close`, then untaint | same reclaim path as waves; untaint only if no NodeClaim |
| Karpenter detection | `kubectl api-versions` lacks `karpenter.sh/` | present |

On kind, label the fake-GPU nodes `karpenter.sh/nodepool=gpu-lendable` (the
harness's job) so the selector finds them.

## Build and deploy

```sh
docker build -t ghcr.io/nycterent/synorg/lending-controller:0.1.3 controllers/lending
kind load docker-image ghcr.io/nycterent/synorg/lending-controller:0.1.3 --name <cluster>
kubectl apply -f clusters/pilot/lending/
```

The image follows the org registry convention
(`ghcr.io/nycterent/synorg/<domain>/<name>`, platform domain) — never a bare Docker
Hub ref: the `synorg/` namespace on docker.io is not org-controlled. The kind
harness path builds and `kind load`s this exact tag locally; on EKS the kubelet
pulls it from the registry. Pin by digest in `lending-controller.yaml` once the
first image is pushed (no real image exists yet, so there is no digest to pin
today).

The Deployment runs non-root with `readOnlyRootFilesystem: true`; the kubectl
cache writes to `KUBECTL_CACHE_DIR=/tmp/kubectl-cache` on an emptyDir.

## Liveness (loop-alive, not tick-success)

`reconcile.sh` touches `$KUBECTL_CACHE_DIR/heartbeat` at startup (before the
first tick) and again after **every** tick — including ticks skipped by
`schedule_invalid` and handled tick failures. The Deployment's exec
`livenessProbe` asserts that file is fresher than 300 s (5 missed ticks at
`TICK_SECONDS=60`; `initialDelaySeconds: 90` covers validate + first tick). A
stale heartbeat therefore means the **loop itself is wedged** (hung process),
not that a tick failed — per-tick errors are logged and the loop continues.
Every kubectl request is additionally bounded by `--request-timeout=30s` in
`kc()`, so a stalled API server cannot wedge a tick indefinitely in the first
place.

## Tests

```sh
bash controllers/lending/test.sh --offline   # syntax + RBAC subset + malformed schedules (no cluster)
bash controllers/lending/test.sh             # + live scenarios against the pinned kubecontext
```

Offline covers syntax, the RBAC-verb-subset check, and three malformed-schedule
scenarios (garbage YAML, a malformed time `"6:3x"`, a bad day name) — each must
log `schedule_invalid` and exit clean **without reaching any kubectl call**.

Live scenarios (U1 kind harness drives these; they run against the pinned
kubecontext and clean up after themselves): window open adds the lent taint /
closed removes it; a shrunk curve patches `borrowingLimit` to match (skips if
the `training-borrow` ClusterQueue is absent); a reclaim tick on a
Karpenter-less cluster logs the intent without erroring; a close-boundary tick
(`closesAt` == wave `startsAt`) routes the still-lent node through the reclaim
path (`reclaim_intent` + `reason=window_close`) before the degradation untaint;
a due wave fires exactly once across 3 ticks (fired-waves marker file).

## How the real operator replaces this

Drop-in: build the operator into the same image reference (or bump the tag in
`lending-controller.yaml`) — Deployment, ServiceAccount, RBAC, and schedule
ConfigMap are already shaped for it. The operator must (a) keep the write
surface and event reasons above, (b) turn on leader election using the granted
lease verbs, (c) add what v0 stubs: scrub verification (new instance-id →
`NodeScrubbed`), `preferPreScrubbed`/`nightScrubRotation`, quarantine
(`NodeQuarantined`), and wave lead-time math from
`nodeReturnToServiceBudgetSeconds`. It must **not** need any new RBAC verb —
if it seems to, re-read the drift-trap comment first.
