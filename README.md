# synorg platform monorepo

Multi-region GPU compute platform on EKS. Git is the only write API; ArgoCD
reconciles; policy verdicts replace approval queues. See
`docs/plans/2026-07-17-001-feat-eks-gpu-platform-plan.md` for the plan and
`eks-platform.prd` for product intent.

## Proven end-to-end

The walking skeleton passed 6/6 live on real EKS GPUs (us-east-1, g4dn)
on 2026-07-18: capacity lend → wave-driven reclaim (198 s ahead of the ramp
deadline) → node scrub onto a genuinely new instance → service rejoin
(p95 0.047 s) → game-day storm, 2 scenarios × 3 runs, 18/18 gates →
lending ledger zero-net-release. The full run record — six `--test` runs
from 0/6 to 6/6 plus both teardown passes — is archived verbatim in
`build/e2e/logs-20260718/`; the harness and procedure are
`tests/e2e/run.sh` and `runbooks/e2e-gpu-run.md`.

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

## Roadmap

Post-skeleton work, each with its decision record:

- Validate the real GitOps remote end-to-end, then delete the direct-sync
  workaround — ADR 0006 (`docs/adr/0006-gitops-remote-and-direct-sync-retirement.md`)
- Migrate images to ghcr.io as the canonical registry; retire ECR and the
  `registry.synorg.io` placeholder — ADR 0007 (`docs/adr/0007-registry-ghcr-canonical.md`)
- Deactivate/requeue borrowing Workloads during reclaim windows to end the
  admit/re-pend tail-chase — ADR 0008 (`docs/adr/0008-kueue-reclaim-keeps-borrowers-admitted.md`)
- Full clean-cycle e2e from zero (no `E2E_KEEP`) as the gate for the two
  migrations above
- Regional spot quota unlock (three regions currently at spot=0) to exercise
  multi-region arbitrage — ADR 0001/0002 become live rather than latent
