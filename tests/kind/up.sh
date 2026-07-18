#!/usr/bin/env bash
# up.sh — bring up the kind integration harness (U1): a cluster whose real
# workers advertise nvidia.com/gpu on labeled/tainted GPU-pool nodes, with
# Kyverno + Kueue installed and the repo's policies/ + clusters/pilot/kueue/
# applied. Idempotent: re-running against an existing cluster is safe.
#
# The REAL kind workers (tests/kind/cluster.yaml) carry the GPU pool labels
# and taints; fake-gpu-operator's device plugin (needs a real kubelet)
# advertises synthetic nvidia.com/gpu there, so pods actually run and real
# PriorityClass preemption + admission fire.
#
# Karpenter is NEVER installed here (validated live, runs 6-9): a live
# Karpenter controller garbage-collects these workers — they carry
# karpenter.sh/nodepool labels (required so the unmodified Kueue
# ResourceFlavors bind; KTD2, the labels cannot be removed) but have no
# backing instance in Karpenter's cloudprovider list, so leaked-node GC
# cordons them and kills the scheduling scenarios. The kwok/Karpenter
# coverage runs in its own ephemeral cluster: tests/kind/kwok-up.sh.
#
# Flags:
#   --fallback   Skip fake-gpu-operator; advertise nvidia.com/gpu by patching
#                node status directly (kubectl patch --subresource=status).
#                The operator release is uninstalled so the two paths never
#                fight over node status. Scheduling fidelity only.
#
# Env equivalent: FALLBACK=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# --- Pinned versions --------------------------------------------------------
# KYVERNO_VERSION matches the CLI pin in .github/workflows/validate.yaml so the
# admission controller enforcing policies here is the same version `make
# validate` tests them with offline. The kindest/node image (k8s 1.33) is
# pinned in cluster.yaml and matches K8S_VERSION in scripts/validate.sh.
KYVERNO_VERSION="v1.18.2"
KUEUE_VERSION="v0.18.3"
FAKE_GPU_OPERATOR_VERSION="0.0.70"   # chart oci://ghcr.io/run-ai/fake-gpu-operator

GPU_OP_NS="gpu-operator"
GPU_COUNT="8"                        # simulated GPUs per GPU worker
CLUSTER_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$HERE/cluster.yaml")"
KCTX="kind-${CLUSTER_NAME}"

# --- Helpers (mirrors scripts/validate.sh) ----------------------------------
fail() { echo "KIND-UP FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) before bringing the harness up"; }
step() { echo; echo "==> $*"; }
# retry MAX CMD... — re-run CMD every 5s until it succeeds or MAX attempts pass.
retry() {
  local max="$1" n=0; shift
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge "$max" ] && return 1
    sleep 5
  done
}
# All kubectl calls target the harness context explicitly so the user's current
# context is never assumed or clobbered.
k() { kubectl --context "$KCTX" "$@"; }

usage() {
  # Print the header comment block (everything up to the first non-comment line).
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

FALLBACK="${FALLBACK:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --fallback) FALLBACK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown flag: $1 (see --help)" ;;
  esac
  shift
done

# --- Preflight ---------------------------------------------------------------
need kind
need docker
need kubectl
need helm
need jq
docker info >/dev/null 2>&1 || fail "docker daemon is not running — start Docker Desktop (or colima) first"
[ -n "$CLUSTER_NAME" ] || fail "could not read cluster name from $HERE/cluster.yaml"

# --- 1. Cluster --------------------------------------------------------------
step "kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "cluster already exists — reusing (idempotent re-run)"
else
  kind create cluster --config "$HERE/cluster.yaml" --wait 120s
fi
k get nodes >/dev/null || fail "cluster '$CLUSTER_NAME' is not reachable via context $KCTX"

# Real GPU workers, discovered by pool label (never by kind's node naming).
WARM_NODE="$(k get nodes -l pool.synorg.io/name=warm-floor -o jsonpath='{.items[0].metadata.name}')"
LEND_NODE="$(k get nodes -l pool.synorg.io/name=lendable -o jsonpath='{.items[0].metadata.name}')"
WEB_NODE="$(k get nodes -l pool.synorg.io/name=web -o jsonpath='{.items[0].metadata.name}')"
[ -n "$WARM_NODE" ] && [ -n "$LEND_NODE" ] && [ -n "$WEB_NODE" ] \
  || fail "expected one node per pool (warm-floor/lendable/web) — recreate the cluster: bash $HERE/down.sh && bash $HERE/up.sh"

# --- 2. Precheck: ValidatingAdmissionPolicy v1 must be served ----------------
# U2's cross-namespace VAP test silently no-ops if the API is absent (k8s <1.30
# node image), so fail loudly here instead of passing vacuously later.
step "precheck: admissionregistration.k8s.io/v1 ValidatingAdmissionPolicy served"
k api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
  | grep -q '^validatingadmissionpolicies\.' \
  || fail "ValidatingAdmissionPolicy v1 is not served — the kindest/node image in cluster.yaml must be k8s >= 1.30"
echo "OK"

# --- 3. Kyverno (pinned to the repo's CLI version) ---------------------------
step "kyverno $KYVERNO_VERSION"
# Server-side apply: the Kyverno CRDs exceed the client-side annotation limit.
k apply --server-side --force-conflicts \
  -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
k -n kyverno wait deploy --all --for=condition=Available --timeout=300s

# --- 4. Kueue ----------------------------------------------------------------
step "kueue $KUEUE_VERSION"
k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
k -n kueue-system rollout status deploy/kueue-controller-manager --timeout=300s

# --- 5. nvidia.com/gpu capacity on the REAL GPU workers ----------------------
# The resource name stays nvidia.com/gpu and the workload manifests stay
# unmodified — fake-ness is confined to how the node advertises capacity.

# gpu_capacity_ready — both GPU workers report non-empty, non-zero allocatable.
gpu_capacity_ready() {
  local n cap
  for n in "$WARM_NODE" "$LEND_NODE"; do
    cap="$(k get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
    [ -n "$cap" ] && [ "$cap" != "0" ] || return 1
  done
}

# The chart's device-plugin DaemonSet only tolerates nvidia.com/gpu:NoSchedule,
# so it would never land on our pool-tainted workers. The harness adapts the
# node/provider side (never the workload under test): append the pool
# tolerations to every operator DaemonSet. Idempotent — skips keys already
# present, so re-runs never duplicate.
gpu_ds_present() { [ -n "$(k -n "$GPU_OP_NS" get ds -o name 2>/dev/null)" ]; }
patch_gpu_ds_tolerations() {
  local ds key ds_json have
  retry 24 gpu_ds_present || fail "fake-gpu-operator DaemonSets never appeared in namespace $GPU_OP_NS"
  for ds in $(k -n "$GPU_OP_NS" get ds -o name); do
    # One fetch per DaemonSet; all three toleration keys are checked from it.
    ds_json="$(k -n "$GPU_OP_NS" get "$ds" -o json 2>/dev/null)"
    for key in pool.synorg.io/warm-floor pool.synorg.io/lendable lending.synorg.io/lent; do
      have="$(echo "$ds_json" | jq -r --arg k "$key" '.spec.template.spec.tolerations // [] | any(.key == $k)')"
      [ "$have" = "true" ] && continue
      k -n "$GPU_OP_NS" patch "$ds" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations/-\",\"value\":{\"key\":\"$key\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}}]" 2>/dev/null \
        || k -n "$GPU_OP_NS" patch "$ds" --type=json \
             -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations\",\"value\":[{\"key\":\"$key\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}]"
    done
  done
}

install_fake_gpu_operator() {
  # No --wait: the device-plugin DaemonSet cannot schedule until the toleration
  # patch below lands, so a helm wait here would deadlock against itself.
  # --force-conflicts: re-runs hit an SSA conflict on .spec.template.spec
  # .tolerations, which patch_gpu_ds_tolerations took ownership of (helm 4
  # applies server-side); helm reclaims the field, then the patch re-adds.
  helm --kube-context "$KCTX" upgrade --install gpu-operator \
    oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator \
    --version "$FAKE_GPU_OPERATOR_VERSION" \
    --namespace "$GPU_OP_NS" --create-namespace \
    --set "topology.nodePools.default.gpuCount=${GPU_COUNT}" \
    --set computeDomainController.enabled=false \
    --force-conflicts \
    && patch_gpu_ds_tolerations
  # computeDomainController is disabled because its DeviceClass template needs
  # the DRA resource.k8s.io API, which kindest v1.33 does not serve by default;
  # the device-plugin path (all we use) does not depend on it.
}

# Fallback: advertise the extended resource by patching node status directly
# (the documented extended-resource mechanism). Scheduling-level fidelity only;
# the advertisement does not survive a kubelet restart. The operator release is
# removed first so the two paths never fight over node status.
advertise_gpus_via_status_patch() {
  helm --kube-context "$KCTX" uninstall gpu-operator -n "$GPU_OP_NS" >/dev/null 2>&1 || true
  local n
  for n in "$WARM_NODE" "$LEND_NODE"; do
    k patch node "$n" --subresource=status --type=merge \
      -p "{\"status\":{\"capacity\":{\"nvidia.com/gpu\":\"${GPU_COUNT}\"},\"allocatable\":{\"nvidia.com/gpu\":\"${GPU_COUNT}\"}}}"
  done
}

GPU_MODE="operator"
if [ "$FALLBACK" = "1" ]; then
  step "GPU capacity: node-status patch (--fallback, operator forced off)"
  advertise_gpus_via_status_patch
  GPU_MODE="fallback"
else
  step "GPU capacity: fake-gpu-operator $FAKE_GPU_OPERATOR_VERSION"
  if install_fake_gpu_operator && retry 60 gpu_capacity_ready; then
    echo "nvidia.com/gpu advertised by fake-gpu-operator on $WARM_NODE + $LEND_NODE"
  else
    echo "WARN: fake-gpu-operator unavailable (image/chart pull or capacity timeout) — falling back to node-status patch" >&2
    advertise_gpus_via_status_patch
    GPU_MODE="fallback"
  fi
fi
retry 12 gpu_capacity_ready || fail "GPU workers never advertised nvidia.com/gpu (mode: $GPU_MODE)"

# --- 6. Repo policies (unmodified) -------------------------------------------
step "apply policies/ (kyverno + vap)"
k apply --server-side --force-conflicts -f "$ROOT/policies/kyverno/"
k apply --server-side --force-conflicts -f "$ROOT/policies/vap/"
retry 24 k wait --for=condition=Ready clusterpolicy --all --timeout=10s \
  || fail "Kyverno ClusterPolicies never became Ready"

# --- 7. Repo Kueue objects (unmodified) --------------------------------------
step "apply clusters/pilot/kueue/"
# team-ml is the namespace clusters/pilot/kueue/localqueue-team-example.yaml
# expects; creating it is harness setup, not a manifest change.
k create namespace team-ml --dry-run=client -o yaml | k apply -f -
# Retried: the Kueue validating webhook can lag its Deployment rollout.
retry 24 k apply --server-side --force-conflicts -f "$ROOT/clusters/pilot/kueue/" \
  || fail "could not apply clusters/pilot/kueue/ (Kueue webhook not admitting?)"

# --- 8. Self-verify ----------------------------------------------------------
step "verify"
SYNORG_KCTX="$KCTX" SYNORG_GPU_MODE="$GPU_MODE" bash "$HERE/verify.sh"

echo
echo "harness up: cluster '$CLUSTER_NAME' (context $KCTX), GPU mode: $GPU_MODE"
