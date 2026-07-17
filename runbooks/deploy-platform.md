# Deploy the platform from zero

Stand up the management cluster and a first region spoke, from an empty AWS
account to a converging, policy-guarded, lending-capable pilot. This is a how-to
for an infrastructure engineer who already understands the
[architecture](../explanation/architecture.md) — it assumes you know what a
NodePool, an ApplicationSet, and an ODCR are, and why the order below matters.

!!! warning "Capacity is irreversible"
    Held GPU capacity, once released, may not come back. Every step that touches
    reservations is verify-before-terminate. Never let a step release capacity
    as a side effect — that is a hard stop, not a retry.

![Bootstrap sequence: ODCR capture, then management cluster with ArgoCD, pilot region with Karpenter, register the scoped spoke, policy plane, scheduling and lending, evidence plane, and finally a game-day gate that must pass before the lending window is enabled; a failed gate loops back to raise the warm floor and re-run](../assets/diagrams/deploy-bootstrap.svg){ .diagram }

## Prerequisites

- An AWS account with GPU instance quota (or ODCR grants) in the target EU
  region, and permissions for EKS, EC2, IAM, S3, KMS.
- `terraform`, `helm`, `kubectl`, `kyverno`, `aws` CLIs authenticated to that
  account.
- The monorepo cloned, `make validate` green locally (proves the artifacts
  before any apply).
- The incumbent central secret manager reachable, with a maintained External
  Secrets Operator provider (verify this before U5 — it is an unowned upstream
  dependency).
- Remote state wired per module: copy `infra/terraform/backend.tf.example` into
  each module dir as `backend.tf` (unique key per module) or pass the same
  values via `-backend-config`.

## Scripted path: `make deploy`

`scripts/deploy.sh` automates sections 1–7 below in this exact order, with the
same credential gate, human-gated ODCR apply, and the
[zero-net-release guard](capacity-carve.md) between capacity steps. This
runbook stays the authoritative narrative — the script references these
sections and adds nothing the runbook does not describe.

```bash
make deploy ARGS=--dry-run   # print the full command sequence (offline)
make deploy ARGS=--plan      # terraform plan per module, read creds, no apply
make deploy                  # full bootstrap (prompts per module apply)
```

It refuses to run without AWS credentials, and every step is idempotent — a
re-run after a partial apply resumes without duplicating reservations.

## 1. Capture held capacity (U15) — before anything else

If GPUs are already running (on ECS or bare instances) that this platform will
adopt, reserve them *in place* first so nothing is released later.

```bash
cd infra/terraform/regions/pilot/odcr
terraform init -backend=false        # wire real backend for a live apply
terraform apply -var-file=held.tfvars   # open ODCRs matching the running instances
```

Confirm reservation utilization equals the running instance count **before**
proceeding. Record it in `docs/capacity-transition.md`. Full carve procedure:
[capture & carve held capacity](capacity-carve.md).

## 2. Management cluster + ArgoCD hub (U2)

```bash
cd infra/terraform/mgmt
terraform init && terraform apply       # EKS management cluster
aws eks update-kubeconfig --name <mgmt-cluster>
kubectl apply -f ../../clusters/mgmt/argocd/install.yaml   # ArgoCD, exec disabled, TLS on
```

Wait for ArgoCD to be healthy. The hub has no workloads of its own beyond
ArgoCD; it exists to reconcile spokes.

## 3. Pilot region cluster + Karpenter held fleet (U3)

```bash
cd infra/terraform/regions/pilot
terraform init && terraform apply       # EKS pilot cluster + Karpenter, ODCR ARNs wired in
```

This installs Karpenter and the three NodePools (warm-floor, lendable, web). The
warm floor is held by the balloon Deployment — confirm it schedules and holds
its floor of GPU nodes:

```bash
kubectl -n platform-system get deploy warm-floor-balloon
kubectl get nodepools
```

## 4. Register the spoke with the hub

Add the pilot cluster to ArgoCD as a **scoped** cluster secret (an assume-role
limited to that spoke, never fleet-wide admin — KTD7), labelled so the
ApplicationSets pick it up:

```bash
argocd cluster add <pilot-context> \
  --name pilot --label synorg.io/role=spoke
```

The `regions` and `services` ApplicationSets now generate one Application per
component overlay and per service values file for the pilot.

## 5. Policy plane (U5)

Apply the Kyverno policies and the ValidatingAdmissionPolicies (these normally
converge via ArgoCD once the spoke is registered; apply directly only for the
first bootstrap):

```bash
kubectl apply -f policies/kyverno/
kubectl apply -f policies/vap/
kyverno test policies/tests --detailed-results   # sanity: 23/23 pass
```

From here, admission is guarded: GPU pods need a team label, customer-data never
tolerates lendable, inline secrets are denied, ESO stores are namespace-scoped.

## 6. Scheduling and lending (U6–U8)

The Kueue objects, lending schedule, and lending controller converge via ArgoCD
from `clusters/pilot/kueue/`, `clusters/pilot/lending/`. Confirm:

```bash
kubectl get clusterqueues                       # training-borrow, platform-lendable
kubectl -n lending get deploy lending-controller
kubectl -n lending get cm lending-schedule -o yaml   # the git-controlled window + curve
```

Do **not** enable a real lending window until the game-day gate passes (next
step). The schedule is the only write path for lending intent — change it by PR,
never by hand.

## 7. Evidence plane (U9)

```bash
kubectl get applications -n argocd | grep observability   # prometheus-stack, rules
```

Confirm render-start p95, DCGM utilization, and per-team GPU-hour attribution
series are populating. Attribution needs the kube-state-metrics pod-label
allow-list configured (see the observability values) — verify a test GPU pod
shows up attributed to its team.

## 8. Gate on a game-day, then enable lending

Before the first real lending window, rehearse the morning-reclaim storm and
prove the latency floor holds: [run a game-day](game-day.md). Only after it
passes, open the lending window by PR to `clusters/pilot/lending/schedule.yaml`.

## Verify the whole path

- A PR changing a golden-chart values file converges to the spoke and the
  service runs.
- A deliberately unsafe change (customer-data pod tolerating lendable) is
  rejected — by `make validate` locally and by admission on the cluster.
- The evidence plane attributes every GPU-hour to a team.
- No step released held capacity (`docs/capacity-transition.md` ledger shows
  zero net release).

## Next

- Day-2: [operations](operations.md).
- Migrate the first real service: [migrate a service](service-migration.md).
- Add regions: each is a Terraform module instantiation + overlay dir + a
  registered scoped spoke secret; the ApplicationSets do the rest.
