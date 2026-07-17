# env-spec retirement schedule

The **env-spec** DSL and its bridge (`tools/env-spec-bridge/`) are temporary
(R4). Each service is translated once by the bridge, reviewed, then owned as
golden-service values; the env-spec original is deleted on a published date. The
DSL dies entirely when the last consumer converts — that is the same PR that
retires ECS (`docs/ecs-retirement.md`), and it removes the bridge tool too
(R4/R11 end state: zero bespoke DSLs).

## Rule

- **Before** a service's *env-spec deleted* date: the service may deploy from
  either its env-spec (via the bridge) or its committed golden values. The
  bridge output must match the committed values.
- **On/after** that date: the env-spec file is removed from the repo. Any
  attempt to deploy the service from a raw env-spec artifact **fails
  `make validate`** — the golden values file under `clusters/<region>/services/`
  (or `.../web/`) is the only deploy path. There is no env-spec fallback.
- The retirement **date is set when the service converts** (reaches 100% on EKS
  at ECS-baseline parity), not guessed up front. Rows below carry a date only
  once that service has converted; pending rows show `—`.

## Schedule

| Service | Class | Converted (100% EKS) | env-spec deleted | Golden values path |
|---|---|---|---|---|
| _(pilot)_ `recommender/ranker` | inference | — | — | `clusters/pilot/services/example-inference.yaml` |
| _(wave 1)_ inference fleet | inference | — | — | `clusters/pilot/services/*.yaml` |
| _(wave 2+)_ web fleet | web | — | — | `clusters/*/web/*.yaml` |

> Placeholder rows. Each real service gets its own row filled in at conversion:
> `Converted` = date the ALB weight reached 100% EKS with a full week of
> baseline-parity metrics (U13 verification); `env-spec deleted` = the date its
> env-spec file was removed and validate began rejecting the old artifact.

## Tool retirement

`tools/env-spec-bridge/` is deleted in the ECS-retirement PR once every row
above has an `env-spec deleted` date. At that point no env-spec exists to
translate and no bespoke DSL remains in the repo. See `docs/ecs-retirement.md`.
