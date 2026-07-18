# The test ladder

Why the platform's verification is shaped as a ladder — `make validate` →
`make integration` → `make smoke` → `make e2e` — and what each rung can and
cannot see. This explains the design; it does not run it. To run the first
rung, start with the [first-validation tutorial](../tutorials/first-validation.md);
to run the last, follow the [e2e runsheet](../runbooks/e2e-gpu-run.md). For the
system the ladder tests, read [architecture](architecture.md).

## Why a ladder at all

No single test environment can be simultaneously cheap, fast, and real. An
offline render costs nothing and finishes in seconds but sees no API server; a
real spot-GPU cluster sees everything but costs money, minutes, and credentials.
Rather than pick one point on that curve, the platform stakes out four, each
rung adding fidelity the one below cannot have and inheriting the confidence of
the ones beneath it. A regression should be caught at the cheapest rung capable
of seeing it — a schema typo dies in `validate`, a wrong toleration in
`integration`, a broken live install in `smoke`, and only GPU physics waits for
`e2e`.

The rungs are Makefile targets, so the ladder is discoverable from `make help`
and each tier runs byte-for-byte the same locally and in CI.

## What each tier proves — and cannot see

| Tier | Command | Proves | Cannot see | Runs in |
|---|---|---|---|---|
| Offline | `make validate` | Charts render; schemas hold; Kyverno policies accept/deny the *rendered* output (CLI, offline) | No API server: webhook ordering, CEL admission at v1, controller behavior | laptop + CI on every PR (`validate.yaml`) |
| Integration | `make integration` | Real admission verdicts and real Kueue quota/preemption on a disposable kind cluster with fake-GPU capacity; Karpenter-core provisioning/consolidation/drift on a second, isolated kwok cluster | The AWS layer: `EC2NodeClass`, ODCR, real EC2 provisioning, scrub-by-termination, DCGM metrics | laptop + CI on PRs touching platform paths (`integration.yaml`) |
| Smoke | `make smoke` | A *live* cluster — kind or EKS, current kubecontext — is healthy and still enforcing platform behavior | Nothing new about the manifests; it asserts a deployment, not the repo | manual, post-deploy |
| Deploy | `make deploy` | The bootstrap runbook is executable end-to-end with one credential-gated entrypoint (`--plan` for dry-run) | It builds the platform; it does not exercise workloads | manual (needs AWS) |
| e2e | `make e2e` | GPU physics: lend → reclaim → scrub (new instance-id) → serve under the p95 gate, on real spot capacity | Nothing — this is the top rung | manual / `workflow_dispatch` only (`e2e.yaml`) |

Two relationships make this a ladder rather than four unrelated suites. First,
each rung re-checks the layer below in a stronger regime: the integration
admission tests apply the *same rendered output* `make validate` checked
offline, but via `kubectl apply --dry-run=server`, so the live Kyverno webhooks
and ValidatingAdmissionPolicy (CEL) return the verdict a production apply would
get. Second, versions are pinned across rungs — the Kyverno admission
controller on kind (v1.18.2) is the same version the offline CLI pins in
`validate.yaml`, so a pass at one rung is evidence about the same software the
next rung runs.

## Two clusters, kept apart

The integration tier runs two disposable kind clusters, one after the other:

- **The main harness** (`tests/kind/up.sh`) has real kind workers carrying the
  GPU-pool labels and taints from [conventions](../conventions.md), and the
  fake-gpu-operator's device plugin — which needs a real kubelet — advertises
  synthetic `nvidia.com/gpu` on them. Because the capacity is real to the
  kubelet, pods actually *run*, which is what makes preemption tests honest:
  when inference preempts training, a running pod is really evicted, not
  simulated. Karpenter is never installed in this cluster.
- **The isolated kwok cluster** (`tests/kind/kwok-up.sh`) is a single
  control-plane node plus kwok and the Karpenter kwok provider. Karpenter
  provisions virtual nodes there to exercise its provider-agnostic core —
  provisioning under taints, consolidation of empty nodes, drift replacement
  (`tests/kwok/karpenter_test.sh`). Virtual nodes have no kubelet and no
  `nvidia.com/gpu`, and their NodePool is tainted.

The isolation is not taste — it was validated live. The main harness's workers
carry `karpenter.sh/nodepool` labels because the unmodified Kueue
ResourceFlavors key on them, and those labels cannot be removed without
modifying the manifests under test. To a live Karpenter controller, a labeled
node with no backing instance in its cloudprovider list is a *leaked node*:
garbage collection cordons it, killing the scheduling scenarios mid-run. So
the two suites never share a cluster — Karpenter only ever sees nodes it
provisioned itself.

The fake-ness is confined to *how a node advertises capacity*. The workload
manifests, the resource name `nvidia.com/gpu`, and the policies under test are
the production ones, unmodified — testing modified manifests would prove
nothing about production.

## The kind/Karpenter boundary

Karpenter splits cleanly into a provider-agnostic core and an AWS provider, and
the ladder splits with it. The core — NodePool scheduling, taints,
consolidation, drift — runs on kind via the upstream kwok provider and is
covered by the integration tier. Everything that talks to EC2 —
`EC2NodeClass`, ODCR capture, subnet/AMI resolution, scrub-by-instance-
termination, DCGM GPU-physical metrics — cannot exist on kind and defers to
e2e. (`EC2NodeClass` *schema* stays covered offline by `make validate`.) The
kwok provider's `karpenter.kwok.sh/*` instance types are test-only and never
appear in the real overlays.

One consequence: the kwok provider has no published image and is built from
source with `go` + `ko`, so the kwok phase requires a Go toolchain —
`kwok-up.sh` checks for it and fails loudly with an install hint rather than
skipping silently (R6). CI runs both phases; the runner's preinstalled Go
bootstraps the exact toolchain karpenter's `go.mod` pins. When the kwok
cluster is unreachable, the suite skips *loudly* rather than passing quietly,
which is the next point.

## No vacuous passes

The standing rule (plan R6, and the repo's andon principle): a tier that
asserts nothing is a defect, and any tier that goes red stops the line. It
shows up throughout the ladder as deliberate mechanics rather than good
intentions:

- Every admission denial is checked for the *name of the denying policy* in the
  error output, so an unrelated failure (missing namespace, schema error) can
  never impersonate a policy verdict.
- The harness prechecks that ValidatingAdmissionPolicy v1 is actually served
  before tests run, because the VAP tests would silently no-op on an older API
  server.
- On push to main, `validate` runs full-repo instead of diff-scoped, because an
  empty diff would pass vacuously.
- Skips are loud and specific — kwok cluster unreachable, ArgoCD absent on
  kind, TAS out of scope — never silent greens.
- Waits are bounded; assertions pin specific conditions (Workload status
  conditions, pod phase, node taints), never a bare exit code.

## Why e2e is manual

The top rung deploys a spot-GPU pilot: it spends real money, needs AWS
credentials, and touches held capacity whose reservations must never be
released from CI. So `make e2e` is credential-gated, its workflow is
`workflow_dispatch` only, and it has prerequisites (spot quota, the Karpenter
ReservedCapacity feature gate) that must be arranged ahead of time — the
[runsheet](../runbooks/e2e-gpu-run.md) carries them as first-class steps. A
scheduled-CI e2e against an ephemeral GPU account is deliberately deferred:
until then, an unattended cron run would either fail on missing prerequisites
or, worse, prove the wrong thing quietly.

The rung has a budget lever: `E2E_CHEAP=1` runs the same physics on
`g4dn.xlarge` spot (one T4 per node, ~$5–10 per run instead of $30–80) via a
run-scoped sizing overlay that never touches the production manifests. What
cheap mode does and does not prove is spelled out in the runsheet's cheap-mode
section.
