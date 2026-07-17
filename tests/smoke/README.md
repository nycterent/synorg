# Smoke tier (U5)

Fast health + behavior check against **any live cluster** — the tier an
operator runs right after `make deploy` (or against the kind harness from
`tests/kind/up.sh`). Where `make validate` proves the repo offline and
`make integration` proves admission/scheduling on a disposable kind cluster,
smoke asserts the cluster in front of you is healthy **and still enforcing
platform behavior**.

## Run

```bash
make smoke                          # against the CURRENT kubecontext
SMOKE_CONTEXT=kind-synorg make smoke   # pin a context explicitly
bash tests/smoke/smoke.sh --describe   # print the check list, no cluster needed
```

Unlike the integration tier, smoke does **not** pin `kind-synorg`: it targets
whatever your kubeconfig currently points at, so the same script runs unchanged
on kind and EKS.

## Checks

| # | Check | On a cluster without the component |
|---|-------|------------------------------------|
| 1 | Every node Ready | — (always asserted) |
| 2 | ArgoCD Applications all Synced + Healthy | explicit `SKIP` (kind has no ArgoCD) |
| 3 | Golden service (chart + `ci/web.yaml`, same inputs as `make validate`) applies, rolls out Ready, Service answers HTTP 200 | — (always asserted) |
| 4 | Known-bad fixture (`tests/integration/admission/fixtures/inline-secret.yaml`) DENIED at live admission, denial **names** `deny-inline-secrets` | `FAIL` — a platform cluster without its policies is broken, not special |
| 5 | Prometheus reachable + GPU-hour attribution (`team:gpu_allocated:sum`) non-empty | explicit `SKIP` (kind has no metrics stack) |

Behavior checks are hard assertions (plan R6): a down service, an admitted
bad pod, or an empty attribution series on a metrics-bearing cluster all make
smoke exit non-zero. Every check prints a `PASS:` / `SKIP:` / `FAIL:` line and
the run ends with a summary.

## Footprint

Read-only except its own test resources: one throwaway namespace
`team-smoke-<rand>` (the `team-` prefix puts it in scope for
`deny-inline-secrets`) holding the golden-service release, deleted by trap on
exit. The bad-fixture check uses `--dry-run=server`, so nothing bad is ever
persisted. All waits are bounded (`SMOKE_TIMEOUT`, default 120s per wait).

## Env

| Variable | Default | Meaning |
|----------|---------|---------|
| `SMOKE_CONTEXT` | current context | kubecontext to target |
| `SMOKE_TIMEOUT` | `120` | seconds per bounded wait (rollout etc.) |
| `SMOKE_IMAGE` | `nginxinc/nginx-unprivileged:1.27-alpine` | pod image for the golden release — the chart's `ci/` registry is an unpullable placeholder; this one serves 200 on `/` at 8080 |
| `SMOKE_PROM_NAMESPACE` | `observability` | where to look for the Prometheus `:9090` Service (`runbooks/game-day.md` read-API) |

## Requirements

`kubectl`, `helm`, `jq`, `curl` — checked up front with the same
`need`-and-fail shape as `scripts/validate.sh`.
