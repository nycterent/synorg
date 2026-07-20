# synorg platform monorepo
Multi-region GPU compute platform on EKS. Git is the only write API; ArgoCD reconciles; policy verdicts replace approval queues. See [docs/plans/2026-07-17-001-feat-eks-gpu-platform-plan.md](docs/plans/2026-07-17-001-feat-eks-gpu-platform-plan.md) for the plan and [eks-platform.prd](eks-platform.prd) for product intent.
## Live runs on real GPUs
Two live milestones on real EKS GPUs (us-east-1, g4dn):

- **2026-07-18 — walking skeleton, 6/6.** Capacity lend → wave-driven reclaim (198 s ahead of the ramp deadline) → node scrub onto a genuinely new instance → service rejoin (p95 0.047 s) → game-day storm, 2 scenarios × 3 runs, 18/18 gates → lending ledger zero-net-release. Run record: [build/e2e/logs-20260718/](build/e2e/logs-20260718/).
  
- **2026-07-19 — GitOps path + borrower drain, 8/8 from zero.** The same physics re-proven on a full clean cycle where ArgoCD ApplicationSets pulling this repository (and public ghcr images, the controller digest-pinned) did every deploy — the direct-sync bootstrap was deleted the same day (ADR 0006). Two new assertions passed first try: borrower drain and reactivation (ADR 0008 — the Kueue tail-chase fix, controller 0.2.1). Exercising the sync path for the first time surfaced seven latent defects, each fixed and committed the same day. Run record: [build/e2e/logs-20260719/](build/e2e/logs-20260719/).
  

Harness and procedure: [tests/e2e/run.sh](tests/e2e/run.sh) and [runbooks/e2e-gpu-run.md](runbooks/e2e-gpu-run.md).
## Layout
| Path | What lives here |
| --- | --- |
| [`charts/`](charts/) | Golden service chart + training job chart (values+schema = the interface) |
| [`clusters/mgmt/`](clusters/mgmt/) | Hub ArgoCD + ApplicationSets |
| [`clusters/pilot/`](clusters/pilot/) | Pilot region: Karpenter pools, Kueue, lending, observability |
| [`policies/`](policies/) | Kyverno + ValidatingAdmissionPolicy, capability tiers, tests |
| [`infra/terraform/`](infra/terraform/) | Management cluster, region clusters, ODCR capture, checkpoint store |
| [`runbooks/`](runbooks/) | Executable playbooks (scrub, quarantine, carve, game-day) |
| [`rehearsal/`](rehearsal/) | Preemption game-day harness scenarios |
| [`tools/`](tools/) | env-spec migration bridge (dated retirement) |
| [`docs/`](docs/) | Conventions, capability tiers, SLO catalog, capacity ledger |
## Deploy path
PR → `make validate` (helm template → kubeconform → kyverno → rendered diff) → capability-tier lane (auto / human review / deny) → merge → ArgoCD sync. No `kubectl` writes outside break-glass. Humans and agents are distinct principals; see [docs/agent-interface.md](docs/agent-interface.md).
## Quick start
```bash
make validate        # diff-scoped, seconds
make validate-full   # whole repo (nightly CI)
```

Conventions (pool names, taints, priority classes, required labels): [docs/conventions.md](docs/conventions.md).
## Roadmap
- ~~Validate the real GitOps remote end-to-end, then delete the direct-sync workaround — ADR 0006~~ **done 2026-07-19** (8/8 clean cycle)
  
- ~~Migrate images to ghcr.io as canonical registry; retire ECR and the~~ `registry.synorg.io` ~~placeholder — ADR 0007~~ **done 2026-07-19**
  
- ~~Borrower drain: deactivate/requeue borrowing Workloads during the reclaim phase — ADR 0008~~ **done 2026-07-19** (controller 0.2.1)
  
- Teardown hardening: sweep EKS-created security groups and stray Karpenter instances inside `phase_down` (three manual interventions on 2026-07-19 prove the need), and rename the `lending_reclaim_window_active` misnomer (see [docs/glossary.md](docs/glossary.md))
  
- Prod-hardening for borrower drain: deactivated-borrower metric + alert for stuck-drain detection (ADR 0008 consequence)
  
- Regional spot quota unlock (three regions currently at spot=0) to exercise multi-region arbitrage — ADR 0001/0002 become live rather than latent
