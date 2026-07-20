# Agent interface

The **single contract** for an LLM agent — or a new hire (D2: the same doc
serves both) — operating this platform with no human translator in the loop
(PRD user 4). It tells you where every interface surface is: what you edit, how
you validate it, how you observe the result, and how you are attributed. If you
read one file before acting, read this one.

The loop this enables is **propose → validate → observe → correct**, closed by
the agent alone:

1. **Propose** — write/edit a values file and open a PR.
2. **Validate** — `make validate` gives a pass/fail verdict with a named error.
3. **Observe** — read live behavior from the SLO read-API.
4. **Correct** — the error message alone is enough to fix and retry.

![The agent loop as a four-stage cycle: propose (edit a values file, open a PR to the monorepo), validate (make validate returns pass/fail with a named error), observe (read the SLO read-API in slo-definitions.yaml), correct (the error message alone drives the fix and next PR), then back to propose — closed by the agent with no human translator](assets/diagrams/agent-loop.svg)

*Figure 1 — The agent loop — propose (PR), validate (make validate), observe (SLO read-API), correct — closed with no human translator.*

## Repo layout

| Path | What it is | You edit it? |
|---|---|---|
| `charts/golden-service/` | The one serving chart. `values.yaml` + `values.schema.json` = the whole deploy interface (R4). | No (platform-owned) |
| `charts/golden-service/values.schema.json` | Strict schema; the source of truth and the docs (R11). | No |
| `charts/golden-service/README.md` | Every values key, generated from the schema. | No (read it) |
| `clusters/<region>/services/*.yaml` | Serving **values files** — one per inference service. | **Yes** |
| `clusters/<region>/web/*.yaml` | Serving values files — web fleet. | **Yes** |
| `clusters/<region>/lending/schedule.yaml` | Region-local lending windows + borrowingLimit curve. | Yes (PR-gated) |
| `clusters/pilot/observability/slo-definitions.yaml` | The **SLO read-API** (see below). | No (read it) |
| `policies/` | Kyverno ClusterPolicies + VAP; the admission guards. | No |
| `infra/terraform/` | Regions, ODCRs, management hub. | Yes (human-by-exception) |
| `runbooks/*.md` | Executable operational procedures. | Run them |
| `tools/env-spec-bridge/` | Legacy env-spec → values translator (temporary, R4). | Run once per migration |
| `docs/` | This contract, conventions, capability tiers, retirement schedules. | Read |
| `Makefile` / `scripts/validate.sh` | The validation entrypoint. | No |

Names you must use — teams, workload classes, node pools, priority classes,
namespaces — are in [`docs/conventions.md`](./conventions.md). The schema and
policies enforce them.

## Values + schema

- The deploy interface is a **values file** matched against
  `charts/golden-service/values.schema.json`. Nothing else — no ingress config,
  no env DSL, no deploy wiki.
- The schema is **strict** (`additionalProperties: false` everywhere). Required
  keys: `team`, `workloadClass`, `image.repository`, `image.tag`. See
  `charts/golden-service/README.md` for the full key reference.
- Key/effect summary: `workloadClass: inference` gets `inference-critical`
  priority; `inference` + `gpu > 0` adds warm-floor/lendable tolerations,
  warm-floor affinity, and `nvidia.com/gpu` limits; `customerData: true` stamps
  the tenancy label. GPU pods without `team` are policy-denied.

## `make validate` — the entrypoint and its error semantics

```bash
make validate          # diff-scoped: helm template → kubeconform → kyverno test → rendered diff
make validate FULL=1   # full-repo render (nightly CI)
```

Local and CI run the **same** `scripts/validate.sh` byte-for-byte, so a green
run locally means a green run in CI. The verdict is machine-actionable:

- **Missing/unknown values key** — helm/schema fails naming the field, e.g.
  `at '': missing property 'team'` or
  `additional properties 'replicaCount' not allowed`. Fix the named field.
- **Policy failure** — kyverno test reports the failing rule and resource. The
  message is sufficient to self-correct within one retry; do **not** work around
  a policy — a denied change is denied for a reason (`docs/capability-tiers.md`).
- **Bridge failure** — `env-spec-bridge` errors naming the offending key (e.g.
  `env` → project via ESO). Fix the env-spec, do not hand-edit the output.

> Limitation: CEL ValidatingAdmissionPolicy rules are schema-checked only
> offline; their behavioral verdict happens at cluster admission
> (`docs/conventions.md`).

## Capability tiers (where your change lands)

Policy verdicts replace approval queues (R7). Your change falls into a tier by
**blast radius**, not by a label you pick — see
[`docs/capability-tiers.md`](./capability-tiers.md):

- **autonomous** — namespace-scoped, non-prod changes that pass all policies
  (and post-game-day, values-only prod image bumps). Merge gate = `make
  validate` green → auto-merge. **This is where an agent's routine work lands.**
- **human-by-exception** — prod topology/quota/NodePool edits. Branch protection
  requires a *human* approving review; an agent cannot self-approve these.
- **never** — cross-tenant refs and inline secret material. Hard-denied at
  admission; cannot be merged around.

## SLO read-API (observe)

Read live service behavior from `clusters/pilot/observability/slo-definitions.yaml`
— the SLO/metric definitions are the **read-API**. An agent answers questions
like *"what's my service's render-start p95 during this morning's reclaim?"* from
this definition set alone, without a human pulling a dashboard. The definitions
name the metrics, windows, and objectives; you query against them and reason from
the numbers.

## Runbooks are executable

Procedures in `runbooks/` are **executable**, not prose to interpret. An agent
runs a runbook end-to-end — e.g. `runbooks/service-migration.md` (bridge → deploy
→ weight shift → parity check → rollback = weight flip). If a runbook step cannot
be executed as written, that is an interface gap to fix in the runbook, not a
place to improvise.

## Distinct agent principal (attribution, R5)

Humans and agents are **distinct, attributable principals**. The agent commits
under its own **bot identity**, and every change is attributed to that principal:

- GPU-hours and deploys resolve to a team/principal — enforced by
  `require-team-label` so attribution is not optional (R6).
- An **agent-authored**, namespace-scoped, non-prod change auto-passes the
  autonomous gate under the agent's identity.
- A **human-by-exception** change requires a *human* approving review — the agent
  cannot dismiss or self-satisfy that gate.

Commit attribution is the audit trail: who (human or which agent) proposed what,
and which gate cleared it.

## Acceptance scenarios (U11)

The interface is proven when an agent completes all four, with transcript
evidence, and any failure traces to an interface gap fixed in the chart / policy
/ read-API — never an agent-side workaround:

1. **Valid change, autonomous lane.** The agent authors a valid namespace-scoped
   non-prod values change → auto-approved lane → converged → attributed to the
   agent principal.
2. **Invalid change, one-retry self-correct.** The agent submits an invalid
   change; the `make validate` error message **alone** is sufficient for the
   agent to self-correct within one retry (no human explanation needed).
3. **Observe from the read-API.** The agent answers *"what's my service's
   render-start p95 during this morning's reclaim?"* from
   `clusters/pilot/observability/slo-definitions.yaml` alone.
4. **Execute a runbook.** The agent runs a runbook (e.g. service-migration)
   end-to-end.
