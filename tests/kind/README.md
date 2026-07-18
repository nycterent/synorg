# kind integration harness

A reproducible local cluster that looks — to the manifests under test — like
the GPU platform: real workers labeled/tainted as the `gpu-warm-floor` /
`gpu-lendable` / `web` pools (names verbatim from `docs/conventions.md`),
advertising `nvidia.com/gpu`, with Kyverno + Kueue installed and the repo's
`policies/` + `clusters/pilot/kueue/` applied unmodified. Every integration
test (`tests/integration/`) runs against this base.

The harness adapts the node/provider side only. The resource name stays
`nvidia.com/gpu` and the workload manifests stay untouched — fake-ness is
confined to how nodes advertise capacity.

This directory also holds a SECOND, isolated cluster: `kwok-up.sh` /
`kwok-down.sh` bring up a tiny ephemeral kwok/Karpenter cluster
(`kwok-cluster.yaml`, single control-plane node) for the Karpenter-core suite
in `tests/kwok/karpenter_test.sh`. See "Two clusters, kept apart" below for
why the two can never be one.

## Prerequisites

- `brew install kind kubernetes-cli helm` (kind not preinstalled on dev machines)
- Docker daemon running (Docker Desktop or colima)
- `go` + `git` — required by the kwok cluster only (`kwok-up.sh`): the
  Karpenter kwok provider has no published image and is built from source with
  `ko`. The main harness (`up.sh`) needs neither.

`up.sh` and `kwok-up.sh` check their own prerequisites and fail with an
install hint (same `need`/`fail` contract as `scripts/validate.sh`).

## Usage

```sh
bash tests/kind/up.sh              # main harness: create + install + apply + self-verify
bash tests/kind/up.sh --fallback   # advertise GPUs via node-status patch, operator off
bash tests/kind/verify.sh          # re-run the main-harness assertions standalone
bash tests/kind/down.sh            # delete the main cluster (idempotent)

bash tests/kind/kwok-up.sh         # isolated kwok/Karpenter cluster (needs go + git)
bash tests/kwok/karpenter_test.sh  # Karpenter-core lifecycle suite against it
bash tests/kind/kwok-down.sh       # delete the kwok cluster (idempotent)

make integration                   # main phase, then kwok phase
make integration-kwok              # kwok phase alone
make integration-down              # delete BOTH clusters
```

Re-running `up.sh` (or `kwok-up.sh`) against an existing cluster is safe:
cluster creation, installs (server-side apply / `helm upgrade --install`),
patches, and probe pods are all idempotent. All `kubectl`/`helm` calls target
the `kind-synorg` (or `kind-synorg-kwok`) context explicitly; your current
kubecontext is never touched.

## Two clusters, kept apart (KTD2/KTD3)

| Cluster | Nodes | Purpose | GPU capacity |
|---|---|---|---|
| Main harness (`cluster.yaml`, `up.sh`) | Real kind workers, one per pool, labeled `pool.synorg.io/name` + `karpenter.sh/nodepool`, GPU pools tainted per `docs/conventions.md` | GPU scheduling, admission, PriorityClass preemption, Kueue quota — pods actually run on a real kubelet. **No Karpenter.** | `nvidia.com/gpu` via fake-gpu-operator (or fallback patch) |
| Isolated kwok cluster (`kwok-cluster.yaml`, `kwok-up.sh`) | One control-plane node + kwok virtual nodes provisioned at runtime from the test-only `kwok-test` NodePool (`karpenter-kwok.yaml`) | Karpenter-core behavior only: NodePool provisioning, taints, drift, consolidation (`karpenter.kwok.sh/*` instance types) | **None — ever** |

Why isolated (validated live, runs 6-9): a live Karpenter controller
garbage-collects the main harness's workers. They carry
`karpenter.sh/nodepool` labels — required so the unmodified Kueue
ResourceFlavors bind (KTD2; the labels cannot be removed) — but have no
backing instance in Karpenter's cloudprovider list, so leaked-node GC cordons
them and kills the scheduling scenarios. One-cluster coexistence is dead: the
main harness never installs Karpenter, and Karpenter only ever sees nodes it
provisioned itself.

kwok virtual nodes have no kubelet — pods bound there never run — and the
`kwok-test` NodePool template carries a
`karpenter.kwok.sh/virtual=true:NoSchedule` taint, so only the explicitly
tolerating probe workload (`tests/kwok/workloads/`) can land on them.

## GPU advertisement: operator vs fallback

**Default (operator):** [fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator)
(pinned chart, `oci://ghcr.io/run-ai/fake-gpu-operator`) runs a device-plugin
DaemonSet on the real GPU workers (marked `run.ai/simulated-gpu-node-pool` in
`cluster.yaml`), advertising 8 `nvidia.com/gpu` per node through the real
device-plugin path — GPU pods reach `Running`. The chart's DaemonSets only
tolerate `nvidia.com/gpu:NoSchedule`, so `up.sh` appends the pool tolerations
to them (a harness-side node/provider adaptation; idempotent).

**Fallback (`--fallback`, or automatic when the operator chart/image is
unreachable):** the extended resource is patched straight into node status
(`kubectl patch node --subresource=status`), and the operator release is
uninstalled so the two paths never fight over node status. Semantics:

- scheduling, quota, and admission behave identically (the scheduler only reads
  allocatable), and probe pods still run;
- there is no device-plugin allocation path and no GPU "hardware" simulation;
- the advertisement does not survive a kubelet/node restart — re-run `up.sh`.

`verify.sh` prints which mode it verified (`GPU mode: operator|fallback`).

## Pinned versions

| Component | Pin | Where |
|---|---|---|
| kindest/node | `v1.33.7` (k8s 1.33; ≥1.30 required for ValidatingAdmissionPolicy v1) | `cluster.yaml` |
| Kyverno | `v1.18.2` — same as the CLI pin in `.github/workflows/validate.yaml` | `up.sh` |
| Kueue | `v0.18.3` | `up.sh` |
| fake-gpu-operator | chart `0.0.70` | `up.sh` |
| kwok | `v0.8.0` | `kwok-up.sh` |
| Karpenter (kwok provider) | `v1.14.0`, built with ko `v0.19.1` into `build/karpenter-kwok/` | `kwok-up.sh` |
| go | `1.26.5` — pinned by karpenter `v1.14.0`'s `go.mod`; any installed go ≥ 1.21 auto-fetches it via the default `GOTOOLCHAIN=auto` | karpenter `go.mod` (consumed by `kwok-up.sh`) |

## Verification

`up.sh` ends by running `verify.sh`, which asserts: pool nodes advertise
`nvidia.com/gpu` with the exact conventions taints; VAP v1 is served; a
policy-compliant probe GPU pod schedules onto the real lendable worker and
becomes Ready; a plain pod lands on the `web` pool. Probe pods are cleaned up
on exit. The kwok cluster is verified by its own suite,
`tests/kwok/karpenter_test.sh` (which also has an offline `--lint` mode).

On `make integration` failure the failing cluster is left up for debugging;
tear everything down with `make integration-down` (or `bash
tests/kind/down.sh` / `bash tests/kind/kwok-down.sh` individually).
