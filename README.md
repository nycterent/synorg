# synorg platform monorepo

Multi-region GPU compute platform on EKS. Git is the only write API; ArgoCD
reconciles; policy verdicts replace approval queues. See
`docs/plans/2026-07-17-001-feat-eks-gpu-platform-plan.md` for the plan and
`eks-platform.prd` for product intent.

## Layout

| Path | What lives here |
|---|---|
| `charts/` | Golden service chart + training job chart (values+schema = the interface) |
| `clusters/mgmt/` | Hub ArgoCD + ApplicationSets |
| `clusters/pilot/` | Pilot region: Karpenter pools, Kueue, lending, observability |
| `policies/` | Kyverno + ValidatingAdmissionPolicy, capability tiers, tests |
| `infra/terraform/` | Management cluster, region clusters, ODCR capture, checkpoint store |
| `runbooks/` | Executable playbooks (scrub, quarantine, carve, game-day) |
| `rehearsal/` | Preemption game-day harness scenarios |
| `tools/` | env-spec migration bridge (dated retirement) |
| `docs/` | Conventions, capability tiers, SLO catalog, capacity ledger |

## Deploy path

PR → `make validate` (helm template → kubeconform → kyverno → rendered diff)
→ capability-tier lane (auto / human review / deny) → merge → ArgoCD sync.
No `kubectl` writes outside break-glass. Humans and agents are distinct
principals; see `docs/agent-interface.md`.

## Quick start

```bash
make validate        # diff-scoped, seconds
make validate-full   # whole repo (nightly CI)
```

Conventions (pool names, taints, priority classes, required labels):
`docs/conventions.md`.
