# Runbook: onboard a team to preemptible GPU training

Executable steps for an R&D team to run training on lent GPU capacity. Everything
here is git-driven: a namespace, a per-team LocalQueue, and a `training-job`
release. The contract you are opting into is the preemption contract (KTD12):
**your job can be preempted at any time, and when it is you lose at most one
checkpoint interval — ≤5 minutes of work.**

Preconditions: the pilot cluster is live with Kueue installed (U6), the Kueue
ClusterQueues `training-borrow` / `platform-lendable` and PriorityClasses exist
(`clusters/pilot/kueue/`), and the checkpoint store bucket exists
(`infra/terraform/regions/pilot/checkpoint-store/`).

## Variables

```bash
export TEAM=ml                              # your team slug (lowercase)
export NS=team-${TEAM}                      # team namespace (conventions.md)
export QUEUE=team-${TEAM}                   # your LocalQueue (conventions.md)
```

## Step 1 — Namespace

Workloads live in a `team-<name>` namespace; policies scope secrets and
cross-namespace refs to this boundary (conventions.md).

```bash
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
```

## Step 2 — LocalQueue

Add a LocalQueue named `team-<name>` in your namespace, pointing at the shared
`training-borrow` ClusterQueue. Copy `clusters/pilot/kueue/localqueue-team-example.yaml`,
change the name/namespace to yours, and land it by PR (git is the only write path).

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-ml           # -> team-<name>
  namespace: team-ml      # -> team-<name>
spec:
  clusterQueue: training-borrow
```

Verify Kueue accepted it:

```bash
kubectl -n "$NS" get localqueue "$QUEUE" \
  -o jsonpath='{.status.conditions[?(@.type=="Active")].status}{"\n"}'   # want: True
```

## Step 3 — Required labels (non-negotiable)

The `training-job` chart stamps these for you; they are listed here so you know
what admission enforces. A GPU pod missing `team.synorg.io/name` is **denied** by
policy (U5):

- `team.synorg.io/name: <team>` — attribution.
- `workload.synorg.io/class: training` — fixed by the chart.
- `kueue.x-k8s.io/queue-name: <queue>` — routes the Job through Kueue.

You do not set these by hand; you set `team` and `queue` in values and the chart
renders them.

## Step 4 — Checkpoint volume (PVC)

The Job mounts a pinned-name PVC, `training-checkpoints`, at `CHECKPOINT_DIR`.
Create it once per namespace, backed by the shared checkpoint store
(`infra/terraform/regions/pilot/checkpoint-store/` — Mountpoint-S3 CSI by default,
FSx for Lustre when `enable_fsx` is on). It must be `ReadWriteMany` so every
worker in every job shares one checkpoint tree.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: training-checkpoints          # pinned name the chart references
  namespace: team-ml                  # -> team-<name>
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: checkpoint-store  # Mountpoint-S3 CSI / FSx StorageClass
  resources:
    requests:
      storage: 1Ti
```

```bash
kubectl -n "$NS" get pvc training-checkpoints \
  -o jsonpath='{.status.phase}{"\n"}'   # want: Bound
```

## Step 5 — The checkpoint contract (your image's responsibility)

The chart hands your container two env vars and a writable checkpoint path; your
training code must honor them, or preemption will cost you real work:

- `CHECKPOINT_DIR` — write checkpoints here (backed by the shared store).
- `CHECKPOINT_INTERVAL_SECONDS` — checkpoint at least this often (≤300, capped by
  the schema).

Your entrypoint MUST, on start, **resume from the latest checkpoint** under
`CHECKPOINT_DIR` if one exists. On SIGTERM (or the `${CHECKPOINT_DIR}/.final-checkpoint-requested`
marker the preStop hook drops), flush one final checkpoint — you have 120 s.

## Step 6 — Deploy a job

Write a values file (schema-validated; an unknown key or a missing required field
fails by name) and template through the chart:

```yaml
# my-run.yaml
team: ml
queue: team-ml
gpu: 1
workers: 2
image:
  repository: registry.synorg.io/ml/trainer
  tag: "2026-07-17-def456"
checkpoint:
  dir: /mnt/checkpoints/ml
  intervalSeconds: 300
```

```bash
helm template my-run charts/training-job -f my-run.yaml | kubectl -n "$NS" apply -f -
```

The Job is created **suspended**; Kueue unsuspends it when the borrowing curve
has GPU headroom. Watch admission:

```bash
kubectl -n "$NS" get workloads.kueue.x-k8s.io          # QUOTA RESERVED / ADMITTED
kubectl -n "$NS" get job,pods -l team.synorg.io/name="$TEAM"
```

If it stays suspended, the curve has no headroom right now (inference is holding
the capacity) — this is expected, not a failure. The Job admits when the window
opens.

## Step 7 — What preemption feels like

When the lending curve shrinks (planned morning reclaim) or inference preempts
(emergency), your pods get SIGTERM with a **120 s grace**. Expect:

- A final checkpoint flush during the grace (Step 5).
- Pods deleted; the Job's remaining backoff budget absorbs it.
- Re-admission by Kueue when headroom returns, resuming from the last checkpoint.

Net lost work: **≤ one checkpoint interval (≤5 min)**. If you are losing more than
that, your entrypoint is not resuming from the latest checkpoint — fix that first;
tightening cadence below the interval is not the answer (KTD12).

## Guardrails you cannot opt out of

- Your pods run **only** on the lendable pool (`karpenter.sh/nodepool=gpu-lendable`)
  and tolerate only the lendable/lent taints. They physically cannot schedule onto
  the never-lent inference warm floor (R12).
- `priorityClassName: training-preemptible` (never-preempt): training yields to
  inference, never the reverse.
```
