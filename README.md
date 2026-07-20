# synorg platform monorepo

**A GPU inference fleet pays for itself twice — full price by day, and again as idle
capacity at night while R&D buys separate GPUs to train on. synorg lends that idle
inference capacity to training overnight and guarantees it back before the morning
ramp — without ever descaling the held fleet, because scarce GPU capacity that is
released may not come back.**

Multi-region GPU compute platform on EKS. Git is the only write API; ArgoCD
reconciles; policy verdicts replace approval queues. The whole thing is one monorepo
a human or an agent changes by pull request — never `kubectl`.

## The idea in one picture

A single lendable node over 24 hours: it serves production inference by day, is lent
to training overnight, and is reclaimed through staged waves that complete *before*
the morning demand ramp. A separate warm floor serves prod all day and is never lent,
so latency stays safe no matter what training does.

![A 24-hour timeline of one node: a lendable node serves prod by day, goes idle in the evening, is lent to training overnight, drains through staged reclaim waves before the morning ramp, scrubs, and returns to prod; below it, the warm floor serves prod all day and never lends](docs/assets/diagrams/why-lending-day.svg)

The reclaim is real capacity motion, not a scheduler hint: nodes are drained and
**scrubbed** (the instance is discarded and training resumes on a genuinely new one —
GPU memory never survives the boundary), and the lending ledger proves zero net
capacity was released across a cycle.

## How it works

A management-cluster ArgoCD hub reconciles each regional spoke from this repository.
Inside a spoke, Karpenter provisions three node pools (warm-floor, lendable, web),
Kueue admits borrowing training workloads against a schedule-driven quota, a lending
controller actuates the lend/reclaim lifecycle, and Kyverno + a
ValidatingAdmissionPolicy enforce tenancy at the API server.

![Hub-spoke topology: the git monorepo (the only write API) feeds the ArgoCD hub, which syncs each region spoke; inside a spoke Karpenter provisions the warm-floor, lendable, and web NodePools while Kueue, the lending controller, Kyverno and VAP, and Prometheus run alongside](docs/assets/diagrams/architecture-topology.svg)

**Deploy path.** A change is a PR: `make validate` (helm template → kubeconform →
kyverno → rendered diff) runs in CI, the change routes to one of three capability
tiers, and merge is what ArgoCD syncs. No `kubectl` writes outside break-glass.
Humans and agents are distinct principals — an agent opens PRs and reads the SLO API,
but never holds cluster credentials. See [docs/agent-interface.md](docs/agent-interface.md).

![Decision flow for a change: cross-tenant references or secret material are denied at admission (never); prod topology, quota, or NodePool changes need a branch-protection review (human-by-exception); namespace-scoped non-prod changes, or values-only prod changes after the region's game-day gate, whose policies all pass, auto-merge through make validate (autonomous)](docs/assets/diagrams/capability-tiers.svg)

Policy verdicts replace human approval queues — the tiers are enforced by CI, branch
protection, and cluster admission respectively, so none can be merged around. Full
model: [docs/capability-tiers.md](docs/capability-tiers.md).

## Live runs on real GPUs

Two milestones on real EKS GPUs (us-east-1, g4dn), each a full run recorded verbatim
in-repo:

- **2026-07-18 — walking skeleton, 6/6.** Capacity lend → wave-driven reclaim (198 s
  ahead of the ramp deadline) → node scrub onto a genuinely new instance → service
  rejoin (p95 0.047 s) → game-day storm, 2 scenarios × 3 runs, 18/18 gates → lending
  ledger zero-net-release. Log: [build/e2e/logs-20260718/](build/e2e/logs-20260718/).
- **2026-07-19 — GitOps path + borrower drain, 8/8 from zero.** The same physics
  re-proven on a full clean cycle where ArgoCD ApplicationSets pulling this repository
  (and public ghcr images, the controller digest-pinned) did every deploy — the
  direct-sync bootstrap was deleted the same day (ADR 0006). Two new assertions passed
  first try: borrower drain and reactivation (ADR 0008 — the Kueue tail-chase fix,
  controller 0.2.1). Exercising the sync path for the first time surfaced seven latent
  defects — four in the GitOps path itself, three in the controller and test harness —
  each fixed and committed the same day. Log:
  [build/e2e/logs-20260719/](build/e2e/logs-20260719/).

Harness and procedure: [tests/e2e/run.sh](tests/e2e/run.sh) and
[runbooks/e2e-gpu-run.md](runbooks/e2e-gpu-run.md). Background and requirements:
[eks-platform.prd.md](eks-platform.prd.md) and the implementation plan under
[docs/plans/](docs/plans/).

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
| [`docs/`](docs/) | Conventions, capability tiers, SLO catalog, ADRs, glossary |

## Quick start

```bash
make validate        # diff-scoped, seconds
make validate-full   # whole repo (nightly CI)
```

Conventions (pool names, taints, priority classes, required labels):
[docs/conventions.md](docs/conventions.md).

## Roadmap

- ~~Validate the real GitOps remote end-to-end, then delete the direct-sync workaround — ADR 0006~~ **done 2026-07-19** (8/8 clean cycle)
- ~~Migrate images to ghcr.io as canonical registry; retire ECR and the `registry.synorg.io` placeholder — ADR 0007~~ **done 2026-07-19**
- ~~Borrower drain: deactivate/requeue borrowing Workloads during the reclaim phase — ADR 0008~~ **done 2026-07-19** (controller 0.2.1)
- Teardown hardening: sweep EKS-created security groups and stray Karpenter instances inside `phase_down` (three manual interventions on 2026-07-19 prove the need), and rename the `lending_reclaim_window_active` misnomer (see [docs/glossary.md](docs/glossary.md))
- Prod-hardening for borrower drain: deactivated-borrower metric + alert for stuck-drain detection (ADR 0008 consequence)
- Regional spot quota unlock (three regions currently at spot=0) to exercise multi-region arbitrage — ADR 0001/0002 become live rather than latent
