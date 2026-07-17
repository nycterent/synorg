# Platform Conventions

Shared names every manifest, chart, and policy in this repo must use. The schemas and policies enforce these; this file is the human/agent index.

## Node pools (Karpenter NodePool names)

| Pool | Name | Taint | Purpose |
|---|---|---|---|
| Warm floor | `gpu-warm-floor` | `pool.synorg.io/warm-floor=true:NoSchedule` | Never-lent inference floor |
| Lendable GPU | `gpu-lendable` | `pool.synorg.io/lendable=true:NoSchedule`, plus `lending.synorg.io/lent=true:NoSchedule` while lent | Lending window pool |
| Web/system | `web` | none | Non-GPU workloads |

## Priority classes

| Name | Value | Preemption | Used by |
|---|---|---|---|
| `inference-critical` | 1000000 | PreemptLowerPriority | Customer inference (render path) |
| `training-preemptible` | 1000 | Never | R&D training jobs |
| `warm-floor-balloon` | -10 | Never | Warm-floor hold Deployment (evicted instantly) |

## Labels (required — policies deny GPU pods without them)

- `team.synorg.io/name` — owning team (attribution; GPU pods denied if absent)
- `workload.synorg.io/class` — `inference` | `training` | `web`
- `data.synorg.io/customer-data` — `"true"` on customer-data workloads (tenancy guard)

## Kueue

- Training ClusterQueue: `training-borrow` (borrowingLimit curve, git-scheduled)
- LocalQueue per team: `team-<name>` in the team namespace
- Serving is never Kueue-admitted — no queue label on inference workloads

## Lending schedule

- Config: `clusters/pilot/lending/schedule.yaml` — windows + borrowingLimit curve; the only write path is a PR to this file.

## Namespaces

- Team namespaces: `team-<name>` prefix — where workloads live; policies scope secrets and cross-ns refs to this boundary.
- Platform namespaces: `platform-*`, `external-secrets`, `argocd`, `kube-system`, `platform-system` — ClusterSecretStore and platform controllers only.

## Validation

- `make validate` — diff-scoped: helm template → kubeconform → kyverno test → rendered diff
- `make validate FULL=1` — full-repo render (nightly CI)
- Local run and CI run execute the same `scripts/validate.sh` byte-for-byte.
- Limitation: ValidatingAdmissionPolicy (CEL) rules are schema-checked only offline; behavioral CEL evaluation happens at cluster admission (covered by policy fixtures once a cluster exists).
