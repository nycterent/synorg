---
hide:
  - toc
---

# Architecture { .tufte }

This is the map an infrastructure engineer needs before touching the system:
what the pieces are, how they fit, and where control and data flow. It explains
the shape; it does not deploy it (that is [deploy the
platform](../runbooks/deploy-platform.md)) or operate it (that is
[operations](../runbooks/operations.md)). For *why* the platform lends GPUs at
all, read [why-lending](why-lending.md) first — this doc assumes it.

## The shape in one paragraph

One management cluster (the **hub**) reconciles many region clusters (the
**spokes**) from a single git repo. Git is the only write API; ArgoCD is the
only actuator. Each spoke runs the serving-and-training substrate: Karpenter for
GPU capacity, Kueue for quota and borrowing, a lending controller for the
lend/reclaim lifecycle, Kyverno + ValidatingAdmissionPolicy for the policy
plane, and Prometheus for the evidence plane. Nothing is applied to a cluster by
hand.

![Hub-spoke topology: the git monorepo (the only write API) feeds the ArgoCD hub, which syncs each region spoke; inside a spoke Karpenter provisions the warm-floor, lendable, and web NodePools while Kueue, the lending controller, Kyverno + VAP, and Prometheus run alongside](../assets/diagrams/architecture-topology.svg){ .diagram }

## Anatomy of the estate

That shape is instantiated today as two EKS clusters, both v1.33, both in
eu-west-1 — the EU pilot region ([region set](../region-set.md)). The canonical
names live in [conventions](../conventions.md); everything below greps back to
a Terraform module or a manifest in this repo.

| Cluster | Role | Region | EKS | Managed node group | Defined in |
|---|---|---|---|---|---|
| `synorg-mgmt` | hub | eu-west-1 | 1.33 | `hub`: 2× m6i.large (max 4) | `infra/terraform/mgmt/` |
| `synorg-pilot` | spoke | eu-west-1 | 1.33 | `system`: 2× m6i.large (max 3) — Karpenter + add-ons only | `infra/terraform/regions/pilot/` |

The hub's data plane runs ArgoCD and nothing else, behind a private API
endpoint. Future regions are more spokes, not more hub: registering a cluster
secret labelled `synorg.io/role=spoke` is all the `regions` ApplicationSet
needs to generate that spoke's Applications
(`clusters/mgmt/appsets/regions.yaml`).

### AZs and held capacity

<div class="md-has-sidebar" markdown>
<main markdown>

The VPC and subnets are a pre-existing layer, passed into both clusters'
Terraform as variables (`vpc_id`, `subnet_ids`) — the network itself is not
defined in this repo. What the repo does pin is where the GPUs sit: the held
On-Demand Capacity Reservations are per-AZ objects, all declared in
`eu-west-1a` (`infra/terraform/regions/pilot/odcr/`):

| Reservation | Instance type | Count |
|---|---|---|
| `p5-48xlarge-a` | `p5.48xlarge` | 4 |
| `g6e-12xlarge-a` | `g6e.12xlarge` | 8 |
| `g7e-2xlarge-a` | `g7e.2xlarge` | 3 |

</main>
<aside markdown>

Counts are placeholders until the capture: each must equal the running ECS
instance count for that flavor+AZ, recorded in the [capacity transition
ledger](../capacity-transition.md) before apply.

</aside>
</div>

The reservations are `open` (running instances associate in place), carry no
end date, and are guarded by `prevent_destroy` — held capacity never lapses as
a side effect. Each is tagged `synorg.io/held-capacity=true`, which is how the
`gpu-held` EC2NodeClass discovers them: a new reservation joins the fleet with
no manifest edit. Because the reservations are per-AZ, the warm floor they
back is AZ-pinned with them. Alongside the cluster sits the training
checkpoint bucket `synorg-pilot-training-checkpoints` (versioned,
KMS-encrypted; `infra/terraform/regions/pilot/checkpoint-store/`).

### Node pools

<div class="md-has-sidebar" markdown>
<main markdown>

Karpenter provisions all pilot capacity beyond the system node group, from
three NodePools (`clusters/pilot/karpenter/`):

| Pool | Weight | Instance types | Capacity | Taint | Limit | Who lands there |
|---|---|---|---|---|---|---|
| `gpu-warm-floor` | 100 | `p5.48xlarge`, `g6e.12xlarge` | reserved, then on-demand | `pool.synorg.io/warm-floor` | 32 GPUs | inference + the balloon; never consolidated (`budgets: nodes: "0"`) |
| `gpu-lendable` | 50 | `p5.48xlarge`, `g6e.12xlarge` | reserved, then on-demand | `pool.synorg.io/lendable`, plus `lending.synorg.io/lent` while lent | 64 GPUs | training admitted through Kueue during the window |
| `web` | 10 | c/m/r families, generation > 5 | on-demand | none | 1000 CPU | web and system workloads, the lending controller |

Both GPU pools reference the `gpu-held` EC2NodeClass; `web` has its own with
no reservation terms, so web load can never consume held GPU capacity. Every
node carries a `pool.synorg.io/name` label — Kueue's ResourceFlavors and the
lending controller key off the pool names, never off instance types.

</main>
<aside markdown>

`E2E_CHEAP=1` shrinks this surface for the real-GPU e2e: instance lists become
`g4dn.xlarge` (1× T4; spot for the lendable pool), one floor node, two
lendable — same physics, ~$5–10 a run
(`tests/e2e/cheap-overlay/apply.sh`).

</aside>
</div>

### What runs where

![The two clusters and their namespaces: synorg-mgmt runs only the argocd namespace (ArgoCD, ApplicationSets, team AppProjects); synorg-pilot runs karpenter, kueue, lending, platform-system, observability, and team namespaces, drawing on the held ODCRs and the S3 checkpoint store](../assets/diagrams/cluster-anatomy.svg){ .diagram }

On the hub everything lives in `argocd`: ArgoCD itself (Helm chart `argo-cd`
7.7.0, installed once, self-managed thereafter), the `regions` and `services`
ApplicationSets, and one AppProject per team. On the pilot, the `regions`
ApplicationSet maps each `clusters/pilot/<dir>` to an Application named
`pilot-<dir>` targeting a namespace of the same name:

- `karpenter` — the synced NodePool and EC2NodeClass manifests (cluster-scoped
  objects; the Karpenter controller itself is installed with the cluster and
  runs on the system node group).
- `kueue` — the ClusterQueues (`platform-lendable`, `training-borrow`),
  ResourceFlavors, and PriorityClasses, all cluster-scoped. The Kueue
  controller runs in `kueue-system` in the kind harness; its EKS install is
  not yet defined in this repo.
- `lending` — the lending controller and its schedule ConfigMap, region-local
  so reclaim survives a hub outage.
- `platform-system` — the warm-floor balloon Deployment that holds the floor
  warm.
- `observability` — kube-prometheus-stack (`65.x`), dcgm-exporter (`3.x`),
  the evidence-plane recording rules, and the SLO definitions.
- `team-<name>` — one namespace per team: its LocalQueue and its
  golden-chart services (the `services` ApplicationSet renders
  `clusters/pilot/services/*.yaml` into `team-{{.team}}`).

The policy plane is cluster-scoped: five Kyverno ClusterPolicies applied from
`policies/kyverno/` (deploy step 5). The Kyverno controller install is
likewise not yet pinned in the repo. The [deploy
runbook](../runbooks/deploy-platform.md) brings this estate up from zero in
seven steps; the [test ladder](testing.md) proves it at increasing cost before
any of it touches AWS.

## The four planes

The system is easier to reason about as four planes than as a pile of
components. Each answers one question.

![The four planes stacked: a change (PR) flows top-to-bottom through the Contract plane (git monorepo), the Actuation plane (ArgoCD + Karpenter), the Policy plane (Kyverno + ValidatingAdmissionPolicy), and the Evidence plane (Prometheus + DCGM); evidence flows back up to inform the next change](../assets/diagrams/architecture-planes.svg){ .diagram }

- **Contract plane — "what is the desired state?"** The git monorepo. Base
  manifests plus per-region overlays; one golden Helm chart whose
  values(+schema) are the entire deploy interface for ~100 services; a separate
  training-job chart. Humans and agents author here and nowhere else.
- **Actuation plane — "who makes it real?"** Reconcilers only. ArgoCD (hub) syncs
  git to spokes; Karpenter (per spoke) provisions and recycles nodes. No
  imperative prod access; every change is attributable to the commit that caused
  it.
- **Policy plane — "what is allowed?"** Kyverno ClusterPolicies plus in-API-server
  ValidatingAdmissionPolicy (CEL). Verdicts replace approval queues and enforce
  the tenancy boundaries the lending model depends on.
- **Evidence plane — "what is actually happening?"** Prometheus + DCGM as a
  read-API: render-start latency, GPU allocation-vs-kernel utilization, per-team
  GPU-hour attribution, lending/preemption events, capacity scarcity. Machine
  readable so agents read targets, not dashboards.

## Component map

| Component | Plane | Role | Lives in |
|---|---|---|---|
| Golden Helm chart | contract | The deploy interface for all serving workloads (values = API) | `charts/golden-service/` |
| Training-job chart | contract | Preemptible training contract (checkpoint, grace, lendable-only) | `charts/training-job/` |
| ArgoCD hub + ApplicationSets | actuation | Renders overlays/services to spokes; one App per component and per service | `clusters/mgmt/` |
| Karpenter + EC2NodeClass/NodePools | actuation | GPU capacity from ODCR-held fleet; warm-floor / lendable / web pools | `clusters/*/karpenter/`, `infra/terraform/regions/*` |
| Kueue | scheduling | Team quota + git-scheduled borrowing-limit curve for training | `clusters/*/kueue/` |
| Lending controller | actuation | Lend/reclaim lifecycle: Node taint flips, drains, Kueue quota edits, scrub | `clusters/*/lending/` |
| Kyverno + VAP | policy | Tenancy guard, team-label, secret scoping, NetworkPolicy generation | `policies/` |
| Prometheus + DCGM | evidence | SLOs, attribution, scarcity, preemption events | `clusters/*/observability/` |
| ODCR capture | capacity | Hold running instances in reservations before any ECS→EKS carve | `infra/terraform/regions/*/odcr/` |

## Control flow — a change from PR to running

1. An engineer or agent opens a PR against the monorepo — a golden-chart values
   file, an overlay, a policy.
2. `make validate` (the same script locally and in CI) renders the charts,
   schema-checks manifests, runs the Kyverno test suite, and — the load-bearing
   step — applies the real policies to the *rendered* output so a chart that
   would emit a rejected pod fails here, not at admission.
3. The change lands in the right lane by capability tier: autonomous
   (ns-scoped, non-prod, or a policy-passing values-only prod change post
   game-day) can auto-merge; prod topology / quota / NodePool changes need a
   human review; cross-tenant or secret-material changes are denied outright.
4. On merge, the hub's ApplicationSets converge the change to the target spoke.
5. The evidence plane records the result; an agent can read the SLO to confirm.

## Data-plane flow — the lend/reclaim cycle

The serving path and the lending lifecycle are the two flows that matter at
runtime. Serving never passes through Kueue — inference schedules directly and
holds its latency floor via a high PriorityClass. Lending is the controller's
job:

- **Night:** the lending window opens (git schedule); the controller flips
  lendable-pool Node taints so training tolerates them, and shrinks nothing yet.
  Kueue admits training up to the borrowing-limit curve.
- **Pre-ramp:** the controller shrinks the borrowing-limit curve (stops new
  training admission) and runs staged reclaim waves — drain training with the
  120 s grace, then recycle each node.
- **Scrub:** reclaim recycles a node by terminating the instance (fresh VRAM,
  not an in-place reimage) and booting a clean one, verified before it rejoins
  the prod-tolerable pool.
- **Emergency:** if inference demand outruns the curve, kube-scheduler
  PriorityClass preemption evicts training node-level immediately — the fast,
  lossy fallback beneath the planned path.

The states a node moves through under this cycle — the machine the lending
controller drives — are the same ones the [operations runbook](../runbooks/operations.md)
maps its on-call tasks to:

![Node lend/reclaim lifecycle: ProdServing to Idle to Lent to Reclaiming to Scrubbing back to ProdServing, with a Quarantined branch off Lent](../assets/diagrams/node-lifecycle.svg){ .diagram }

The reclaim mechanism — why serving never queues and demand enters Kueue as a
scheduled quota curve — has its own discussion in the reclaim model *(planned:
`reclaim-model.md`)*.

## Load-bearing decisions

The decisions that constrain everything downstream, in one line each (full
rationale in the plan, `docs/plans/`):

- Git is the sole write API; reconcilers the sole actuators — audit, rollback,
  and agent safety cage in one mechanism.
- Golden-chart values(+schema) are the permanent interface; the env-spec bridge
  is a migration bridge with a retirement date.
- Node-level lending with terminate-and-recover scrub before any finer GPU
  sharing — failure-domain and compliance safety first.
- The render path is optimized for latency, the training path for utilization —
  opposite objectives, deliberately.
- Capacity intent lives in git; scarcity is structured evidence, not an error.

## Boundaries and single points

- **The hub is a single control-plane dependency.** If it dies, spokes keep
  serving and lending (their controllers are region-local); only reconciliation
  pauses. It is also a single high-value compromise target — hence per-spoke
  scoped, rotated credentials and alerting on anomalous hub-originated syncs.
- **Trust is reset, not shared.** A node serves one trust domain at a time;
  customer-data and R&D never co-tenant a node, enforced by taints + policy, and
  the between-tenant reset is instance termination.
- **Everything offline-provable stops at the cluster edge.** Chart rendering,
  schema, and policy composition are checkable on a laptop; lending, preemption,
  and sync require a real cluster (see the [deploy
  guide](../runbooks/deploy-platform.md)).
