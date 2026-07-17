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

## Prerequisites

- `brew install kind kubernetes-cli helm` (kind not preinstalled on dev machines)
- Docker daemon running (Docker Desktop or colima)
- `go` + `git` — only for the Karpenter kwok provider, which has no published
  image and is built from source with `ko`; skip with `--no-kwok`

`up.sh` checks each of these and fails with an install hint (same `need`/`fail`
contract as `scripts/validate.sh`).

## Usage

```sh
bash tests/kind/up.sh              # create + install + apply + self-verify
bash tests/kind/up.sh --fallback   # advertise GPUs via node-status patch, operator off
bash tests/kind/up.sh --no-kwok    # skip the Karpenter kwok provider (no Go toolchain)
bash tests/kind/verify.sh          # re-run the assertions standalone
bash tests/kind/down.sh            # delete the cluster (idempotent)
make integration                   # up -> tests/integration/*/ -> down
```

Re-running `up.sh` against an existing cluster is safe: cluster creation,
installs (server-side apply / `helm upgrade --install`), patches, and probe
pods are all idempotent. All `kubectl`/`helm` calls target the `kind-synorg`
context explicitly; your current kubecontext is never touched.

## Two-substrate design (KTD1/KTD2/KTD3)

| Substrate | Nodes | Purpose | GPU capacity |
|---|---|---|---|
| Real kind workers | `cluster.yaml`: one per pool, labeled `pool.synorg.io/name` + `karpenter.sh/nodepool`, GPU pools tainted per `docs/conventions.md` | GPU scheduling, admission, PriorityClass preemption — pods actually run on a real kubelet | `nvidia.com/gpu` via fake-gpu-operator (or fallback patch) |
| kwok virtual nodes | Provisioned at runtime by the Karpenter kwok provider from the test-only `kwok-test` NodePool (`karpenter-kwok.yaml`) | Karpenter-core behavior only: NodePool scheduling, taints, drift, consolidation (`karpenter.kwok.sh/*` instance types) | **None — ever** |

kwok nodes have no kubelet: an `image: fake` pod placed there never runs, so a
GPU workload landing on one would make preemption tests evict non-running pods.
Three fences keep the substrates apart: the `kwok-test` NodePool template
carries a `karpenter.kwok.sh/virtual=true:NoSchedule` taint, kwok nodes never
get the `pool.synorg.io/name` / GPU `karpenter.sh/nodepool` labels the GPU
selectors and Kueue ResourceFlavors key on, and `verify.sh` asserts no kwok
node ever advertises `nvidia.com/gpu`.

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
| kwok | `v0.8.0` | `up.sh` |
| Karpenter (kwok provider) | `v1.14.0`, built with ko `v0.19.1` into `build/karpenter-kwok/` | `up.sh` |

## Verification

`up.sh` ends by running `verify.sh`, which asserts: pool nodes advertise
`nvidia.com/gpu` with the exact conventions taints; VAP v1 is served; a
policy-compliant probe GPU pod schedules onto a real lendable worker (never a
kwok node) and becomes Ready; a plain pod lands on the `web` pool; kwok nodes
advertise no GPU. Probe pods are cleaned up on exit.

On `make integration` failure the cluster is left up for debugging; tear it
down with `make integration-down` (or `bash tests/kind/down.sh`).
