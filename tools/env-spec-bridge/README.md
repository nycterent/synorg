# env-spec-bridge

Mechanical translator from the legacy **env-spec** (the ECS-era deploy DSL) to
**golden-service** Helm values. It exists so GPU inference and web services move
onto the golden chart without a human hand-translating each one (Success
Criterion 5): the bridge is deterministic and zero-interaction — same env-spec
in, same values out, no prompts. It is a **strangler artifact** with a
retirement date: each service is translated once, reviewed, then owned as
values, and the tool is deleted when the last consumer converts (R4). See
[`docs/env-spec-retirement.md`](../../docs/env-spec-retirement.md).

## Usage

```bash
# Print values to stdout
python3 tools/env-spec-bridge/bridge.py path/to/service.envspec.yaml

# Write to a values file
python3 tools/env-spec-bridge/bridge.py path/to/service.envspec.yaml -o clusters/pilot/services/service.yaml

# Validate the result against the golden schema (helm reads values.schema.json)
helm template t charts/golden-service -f clusters/pilot/services/service.yaml >/dev/null
```

The bridge only writes values; it never talks to a cluster or a registry. The
output is reviewed once (the "translated then owned" step of U13), committed, and
from then on maintained as ordinary values — the env-spec original is deleted on
the schedule.

Dependencies: Python 3 + PyYAML only (stdlib otherwise).

## env-spec contract

env-spec is a flat, compose-like YAML. The bridge translates exactly these keys
and nothing else — an unrecognized key is a hard error naming the key (R10), so
nothing is dropped in silence.

| env-spec key | type | required | golden-service target |
|---|---|---|---|
| `service` | string | **yes** | migration identity (not a values key; used for the values filename) |
| `team` | string | **yes** | `team` |
| `class` | `web` \| `inference` | **yes** | `workloadClass` |
| `image` | `repository:tag` | **yes** | `image.repository` + `image.tag` (split on the last `:`) |
| `cpu` | string | **yes** | `resources.requests.cpu` |
| `memory` | string | **yes** | `resources.requests.memory` |
| `cpu_limit` | string | no | `resources.limits.cpu` |
| `memory_limit` | string | no | `resources.limits.memory` |
| `port` | int | no (default 8080) | `port`, `service.targetPort`, and probe ports when unset |
| `replicas` | int | no | `replicas` |
| `gpu` | int | no | `gpu` (emitted only when `> 0`) |
| `customer_data` | bool | no | `customerData` (emitted only when `true`) |
| `healthcheck` | `{path, port}` | no | `probes.liveness` |
| `readiness` | `{path, port}` | no | `probes.readiness` |
| `autoscale` | `{min, max, cpu_target}` | no | `hpa` (`enabled: true`) |
| `disruption_budget` | `{min_available}` | no | `pdb` (`enabled: true`) |

## Bridge semantics (R4)

- **Deterministic.** Output key order is fixed and independent of input order;
  the same env-spec always produces the same bytes. Golden-file tests
  (`fixtures/expected/`) enforce this.
- **No silent drops.** Every top-level and nested key is either translated or
  rejected by name (e.g. `unknown env-spec key 'healthcheck.grace_period'`).
- **Schema is the validator.** The golden-service `values.schema.json` is the
  source of truth (R11); the bridge does not re-implement it. Correctness of an
  output is proven by `helm template` exiting 0.
- **Retired ECS-isms point somewhere.** Keys that were real in ECS but have no
  golden-chart home get a tailored error saying where the concept moved:
  - `env` / `secrets` → project config via an **ESO**-managed ConfigMap/Secret;
    the chart has no env surface by design.
  - `task_role_arn` → IRSA / Pod Identity bound to the workload ServiceAccount.
  - `network_mode`, `launch_type` → no equivalent; scheduling derives from
    `workloadClass` + `gpu`.
- **Probes are fully specified.** The bridge always emits `probes.liveness` and
  `probes.readiness` pinned to the container port, so a service that does not
  listen on 8080 never inherits the chart's 8080 default probe port.

## Retirement

The tool has no standalone lifespan: it is removed in the same PR that empties
ECS (U14, `docs/ecs-retirement.md`). The retirement date is **set when the last
consumer converts**, tracked per service in
[`docs/env-spec-retirement.md`](../../docs/env-spec-retirement.md). After a
service's env-spec-deleted date, any attempt to deploy it from a raw env-spec
fails `make validate` — the golden values file is the only deploy path.

## Tests

```bash
python3 -m pytest tools/env-spec-bridge/ -q
```

`test_bridge.py` covers: golden-file translation of each fixture, `helm
template` schema validation of every generated and committed values file,
determinism, and the error paths (unknown key, retired key → ESO, missing
required key, malformed image, bad class, unknown sub-key). Fixtures live in
`fixtures/`; expected outputs in `fixtures/expected/`; error cases in
`fixtures/errors/`.
