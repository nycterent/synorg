# training-job

The single Helm chart every R&D training workload deploys through — the R4
symmetry twin of `golden-service`. `values.yaml` + `values.schema.json` is the
**whole** interface, and this README is generated from the schema (the schema is
the source of truth, R11).

The schema is **strict** (`additionalProperties: false` everywhere): an unknown
key or a missing required field fails `helm template` / `make validate` with a
message naming the field, e.g.

```
- at '': missing property 'team'
- at '': additional properties 'gpuCount' not allowed
- at '/checkpoint/intervalSeconds': must be <= 300
```

That last one is the point: the checkpoint cadence cap is the KTD12 lost-work
budget expressed as schema — a job that tries to checkpoint less often than every
5 minutes is rejected by name.

## Values

Every key mirrors `values.schema.json`. **Required** keys have no default; a
release that omits one is rejected by name.

| Key | Type | Required | Default | Notes |
|---|---|---|---|---|
| `team` | string (non-empty) | **yes** | — | `team.synorg.io/name` label; GPU pods without it are policy-denied |
| `queue` | string (non-empty) | **yes** | — | Kueue LocalQueue (`team-<name>`); becomes `kueue.x-k8s.io/queue-name` |
| `gpu` | integer ≥ 1 | **yes** | — | GPUs per worker; `nvidia.com/gpu` limit (training is always GPU work) |
| `image.repository` | string (non-empty) | **yes** | — | image repository; entrypoint must resume from `CHECKPOINT_DIR` |
| `image.tag` | string (non-empty) | **yes** | — | immutable tag; also `app.kubernetes.io/version` |
| `image.pullPolicy` | enum `Always` \| `IfNotPresent` \| `Never` | no | `IfNotPresent` | image pull policy |
| `workers` | integer ≥ 1 | no | `1` | worker pods = torchrun-elastic nodes (Indexed Job) |
| `command` | array of string | no | torchrun scaffold | container command override |
| `checkpoint.dir` | string (non-empty) | **yes** | `/mnt/checkpoints` | mount path for checkpoints; published as `CHECKPOINT_DIR` |
| `checkpoint.intervalSeconds` | integer 1–**300** | no | `300` | cadence; published as `CHECKPOINT_INTERVAL_SECONDS`; cap enforces the ≤5 min budget (KTD12) |
| `resources.requests.cpu` | string | no | `"8"` | CPU request quantity |
| `resources.requests.memory` | string | no | `64Gi` | memory request quantity |
| `resources.limits.cpu` | string | no | `"16"` | CPU limit quantity |
| `resources.limits.memory` | string | no | `128Gi` | memory limit quantity |
| `backoffLimit` | integer ≥ 0 | no | `12` | Job backoffLimit; absorbs preemptions (each preemption is a pod failure) |

## The preemption contract (KTD12)

Every rendered Job is built to survive reclaim:

- **Kueue-admitted, suspended.** The Job ships `suspend: true` and the
  `kueue.x-k8s.io/queue-name` label; Kueue admits by unsuspending. Serving never
  carries this label (KTD6).
- **Lendable pool only.** `nodeSelector karpenter.sh/nodepool=gpu-lendable` and
  tolerations for **only** `pool.synorg.io/lendable` + `lending.synorg.io/lent` —
  there is no warm-floor toleration, so these pods physically cannot land on the
  never-lent inference floor (R12 containment).
- **`training-preemptible` priority, never-preempt.** Training yields; it never
  takes capacity.
- **Checkpoint + resume.** `CHECKPOINT_DIR` / `CHECKPOINT_INTERVAL_SECONDS` (≤300)
  drive periodic checkpointing; the entrypoint resumes from the latest checkpoint.
- **120 s grace + preStop flush.** `terminationGracePeriodSeconds: 120` with a
  preStop hook that requests a final checkpoint, so worst-case lost work is one
  interval.

Checkpoints land in the shared checkpoint store
(`infra/terraform/regions/pilot/checkpoint-store/`), sized for every lent node
final-checkpointing at once inside the grace window.

## Rendering

```bash
helm template t charts/training-job -f charts/training-job/ci/basic-training.yaml
```

`ci/basic-training.yaml` is the CI fixture exercised by `make validate`.
