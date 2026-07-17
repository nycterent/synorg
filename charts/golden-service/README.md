# golden-service

The single Helm chart that serves every platform serving workload. `values.yaml`
+ `values.schema.json` is the **whole** deploy interface (R4), and this README is
generated from the schema — the schema is the source of truth (R11). There is no
separate deploy wiki and no ingress here: ALB weighting is handled outside the
chart during the strangler migration.

The schema is **strict** (`additionalProperties: false` everywhere): an unknown
key or a missing required field fails `helm template` / `make validate` with a
message naming the field, e.g.

```
- at '': missing property 'team'
- at '': additional properties 'replicaCount' not allowed
```

## Values

Every key below mirrors `values.schema.json`. **Required** keys have no default;
a release that omits one is rejected by name.

| Key | Type | Required | Default | Notes |
|---|---|---|---|---|
| `team` | string (non-empty) | **yes** | — | `team.synorg.io/name` label; GPU pods without it are policy-denied |
| `workloadClass` | enum `inference` \| `web` | **yes** | — | `workload.synorg.io/class` label; training uses its own chart |
| `image.repository` | string (non-empty) | **yes** | — | image repository |
| `image.tag` | string (non-empty) | **yes** | — | immutable tag; also `app.kubernetes.io/version` |
| `image.pullPolicy` | enum `Always` \| `IfNotPresent` \| `Never` | no | `IfNotPresent` | image pull policy |
| `customerData` | boolean | no | `false` | `true` stamps `data.synorg.io/customer-data="true"` (tenancy guard) |
| `replicas` | integer ≥ 1 | no | `1` | Deployment replicas |
| `gpu` | integer ≥ 0 | no | `0` | GPUs per pod; `>0` adds `nvidia.com/gpu`; with `inference` adds GPU-pool scheduling |
| `port` | integer 1–65535 | no | `8080` | container port |
| `resources.requests.cpu` | string | no | `100m` | CPU request quantity |
| `resources.requests.memory` | string | no | `128Mi` | memory request quantity |
| `resources.limits.cpu` | string | no | `"1"` | CPU limit quantity |
| `resources.limits.memory` | string | no | `512Mi` | memory limit quantity |
| `service.type` | enum `ClusterIP` \| `NodePort` \| `LoadBalancer` | no | `ClusterIP` | Service type |
| `service.port` | integer 1–65535 | no | `80` | Service port |
| `service.targetPort` | integer 1–65535 | no | `8080` | container target port |
| `probes.liveness.path` | string | no | `/healthz` | HTTP liveness path |
| `probes.liveness.port` | integer 1–65535 | no | `8080` | HTTP liveness port |
| `probes.readiness.path` | string | no | `/readyz` | HTTP readiness path |
| `probes.readiness.port` | integer 1–65535 | no | `8080` | HTTP readiness port |
| `hpa.enabled` | boolean | no | `false` | render a HorizontalPodAutoscaler |
| `hpa.minReplicas` | integer ≥ 1 | no | `1` | HPA minimum replicas |
| `hpa.maxReplicas` | integer ≥ 1 | no | `5` | HPA maximum replicas |
| `hpa.targetCPUUtilizationPercentage` | integer 1–100 | no | `80` | target average CPU utilization |
| `pdb.enabled` | boolean | no | `false` | render a PodDisruptionBudget |
| `pdb.minAvailable` | integer ≥ 0 | no | `1` | minimum available pods during voluntary disruption |
| `serviceAccount.create` | boolean | no | `true` | create a ServiceAccount |
| `serviceAccount.name` | string | no | `""` | name; defaults to release fullname when created, else `default` |

## Behavior by class

- **`workloadClass: web`** — cluster-default priority, no GPU scheduling.
- **`workloadClass: inference`** — `priorityClassName: inference-critical` (render
  path preempts training node-level).
- **`inference` + `gpu > 0`** — toleration for `pool.synorg.io/warm-floor`, plus
  `preferred` node affinity for the `gpu-warm-floor` Karpenter NodePool (holds
  the latency floor, R2), and `nvidia.com/gpu` in resource limits. Non-customer-
  data inference **also** tolerates `pool.synorg.io/lendable` to spill under
  pressure; **`customerData: true` inference tolerates warm-floor only** — a lent
  node can be reclaimed and scrubbed for R&D, so `tenancy-guard` denies any
  customer-data pod that tolerates lendable (R9).

Serving is **never** Kueue-admitted — this chart emits no queue label under any
values (KTD6).

## Rendering

```bash
helm template t charts/golden-service -f charts/golden-service/ci/web.yaml
helm template t charts/golden-service -f charts/golden-service/ci/gpu-inference.yaml
```

`ci/web.yaml` (plain web) and `ci/gpu-inference.yaml` (GPU inference, customer
data) are the CI fixtures exercised by `make validate`.
