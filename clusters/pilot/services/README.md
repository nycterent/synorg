# clusters/pilot/services

Golden-service **values files** for serving workloads on the pilot cluster — one
YAML file per service. Each file is the whole deploy interface for that service
(R4): no ingress config, no env DSL, no deploy wiki. The services ApplicationSet
(`clusters/mgmt/appsets/services.yaml`) emits one Application per file and renders
it through `charts/golden-service` as a multi-source Helm app — one converged
service per values file, landing in the owning team's namespace (`team-<team>`).

## What lives here

- **Inference and web serving services** as golden-service values. Web services
  on multi-region clusters live under `clusters/<region>/web/`; pilot inference
  services live here.
- Nothing else. Training uses its own chart (not this values schema); lending,
  Kueue, and observability config live in sibling `clusters/pilot/*` dirs.

## Adding a service

Migrated from ECS: run the bridge once and review the output
(`runbooks/service-migration.md`):

```bash
python3 tools/env-spec-bridge/bridge.py <service>.envspec.yaml -o clusters/pilot/services/<service>.yaml
helm template t charts/golden-service -f clusters/pilot/services/<service>.yaml >/dev/null   # schema check
make validate                                                                                # full gate
```

New service (no env-spec): copy an existing file and edit the values. The schema
(`charts/golden-service/values.schema.json`) is strict — an unknown key or a
missing required field fails `make validate` naming the field.

## Conventions

Values keys and their effects are documented in `charts/golden-service/README.md`
(generated from the schema, which is the source of truth, R11). Platform-wide
names — teams, workload classes, node pools, priority classes — are in
`docs/conventions.md`.

## Example

[`example-inference.yaml`](./example-inference.yaml) — a customer-data GPU
inference service (`workloadClass: inference`, `gpu: 1`, `customerData: true`),
owned as values after a one-time bridge translation. It renders under the golden
chart with `inference-critical` priority, a warm-floor toleration only (as
customer-data, it may not tolerate lendable — `tenancy-guard`, R9), warm-floor
node affinity, and `nvidia.com/gpu` limits.
