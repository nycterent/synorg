# Lending controller (U4 thin v0)

A deliberately thin, `kubectl`-driven reconcile loop that actuates the
git-controlled lending schedule. It replaces the placeholder image in
`clusters/pilot/lending/lending-controller.yaml` with something real and
deployable, so the lend/reclaim lifecycle runs unattended while the full
operator (plan-001 U8) is built. Same Deployment, same RBAC, same schedule —
only the image contents are v0.

## What it does each tick

Reads `SCHEDULE_FILE` (the mounted `lending-schedule` ConfigMap) fresh, then:

1. **Window taints** — if a lending window is open (region-local time, DST via
   the schedule `timezone`), adds `targets.lentTaint` to every Node labeled
   `karpenter.sh/nodepool=<targets.lendablePool>`; removes it when closed.
   Idempotent: only actual transitions act and emit.
2. **Borrow curve** — resolves the active `borrowingLimitCurve` entry (the most
   recently passed `at`, daily recurrence), converts `gpuLimitPct` to an
   absolute quantity against the *current* summed `nvidia.com/gpu` capacity of
   lendable Nodes, and patches the `targets.trainingQueue` ClusterQueue
   `borrowingLimit`. Patches only on change.
3. **Reclaim waves** — a wave is due for `WAVE_FIRE_WINDOW_SECONDS` after its
   `startsAt`. For `ceil(reclaimFraction x currently-lent)` nodes:
   - **EKS** (Karpenter API present): cordon, drain via the eviction API with
     `drainGraceSeconds`, then delete the node's NodeClaim — Karpenter
     terminates the instance, which *is* the scrub boundary (fresh instance,
     fresh AMI).
   - **kind** (no Karpenter API): logs `action=reclaim_intent` with the
     intended cordon+drain+nodeclaim-delete and does nothing. This is by
     construction: kind has no NodeClaims and the ClusterRole grants no
     `nodes: delete`.

A malformed or unsupported schedule (bad YAML, wrong `schemaVersion`, missing
required field) logs `action=schedule_invalid` with the reason and **skips the
tick** — the actuator never crash-loops on bad intent.

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
`EMIT_EVENTS=true`, a Kubernetes Event in the `lending` namespace bound to the
Node or ClusterQueue: `LendWindowOpened`, `NodeLent`, `NodeReturnedToProd`,
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
| Karpenter detection | `kubectl api-versions` lacks `karpenter.sh/` | present |

On kind, label the fake-GPU nodes `karpenter.sh/nodepool=gpu-lendable` (the
harness's job) so the selector finds them.

## Build and deploy

```sh
docker build -t synorg/lending-controller:0.1.0 controllers/lending
kind load docker-image synorg/lending-controller:0.1.0 --name <cluster>
kubectl apply -f clusters/pilot/lending/
```

The Deployment runs non-root with `readOnlyRootFilesystem: true`; the kubectl
cache writes to `KUBECTL_CACHE_DIR=/tmp/kubectl-cache` on an emptyDir.

## Tests

```sh
bash controllers/lending/test.sh --offline   # syntax + RBAC subset + malformed schedule (no cluster)
bash controllers/lending/test.sh             # + live scenarios against the current kubecontext
```

Live scenarios (U1 kind harness drives these; they run against any cluster and
clean up after themselves): window open adds the lent taint / closed removes
it; a shrunk curve patches `borrowingLimit` to match (skips if the
`training-borrow` ClusterQueue is absent); a reclaim tick on a Karpenter-less
cluster logs the intent without erroring.

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
