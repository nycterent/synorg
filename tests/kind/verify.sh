#!/usr/bin/env bash
# verify.sh — executable assertions for the U1 harness. Invoked by up.sh after
# setup; also runnable standalone against an already-up harness cluster.
#
# Asserts:
#   1. GPU workers advertise nvidia.com/gpu and carry the exact pool taints
#      from docs/conventions.md; the web worker has neither.
#   2. ValidatingAdmissionPolicy v1 is served.
#   3. A probe GPU pod (policy-compliant: team label, training class, lendable
#      toleration) schedules onto the REAL lendable worker.
#   4. A plain non-GPU pod stays off GPU nodes (lands on the web pool).
#
# No kwok/Karpenter assertions here: Karpenter is never installed in this
# cluster (it GC-cordons the pool-labeled workers) — it lives in the isolated
# kwok cluster (kwok-up.sh), verified by tests/kwok/karpenter_test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$HERE/cluster.yaml")"
KCTX="${SYNORG_KCTX:-kind-${CLUSTER_NAME}}"
PROBE_NS="team-ml"

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1)"; }
pass() { echo "ok: $*"; }
k() { kubectl --context "$KCTX" "$@"; }

need kubectl
k get nodes >/dev/null 2>&1 || fail "no cluster reachable at context $KCTX — run tests/kind/up.sh first"

# GPU mode: exported by up.sh; when run standalone, detect by whether the
# fake-gpu-operator DaemonSets exist (operator) or not (node-status fallback).
GPU_MODE="${SYNORG_GPU_MODE:-}"
if [ -z "$GPU_MODE" ]; then
  if [ -n "$(k -n gpu-operator get ds -o name 2>/dev/null)" ]; then
    GPU_MODE="operator"
  else
    GPU_MODE="fallback"
  fi
fi

# node_by_pool POOL — resolve the single real worker carrying the pool label.
node_by_pool() {
  k get nodes -l "pool.synorg.io/name=$1" -o jsonpath='{.items[0].metadata.name}'
}
# gpu_allocatable NODE — the node's allocatable nvidia.com/gpu ('' when absent).
gpu_allocatable() {
  k get node "$1" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null
}
# taint_effect NODE KEY — the effect of taint KEY on NODE ('' when absent).
taint_effect() {
  k get node "$1" -o jsonpath="{.spec.taints[?(@.key==\"$2\")].effect}"
}

# --- 1. Node shape: capacity + taints per docs/conventions.md ----------------
WARM_NODE="$(node_by_pool warm-floor)"
LEND_NODE="$(node_by_pool lendable)"
WEB_NODE="$(node_by_pool web)"
[ -n "$WARM_NODE" ] || fail "no node labeled pool.synorg.io/name=warm-floor"
[ -n "$LEND_NODE" ] || fail "no node labeled pool.synorg.io/name=lendable"
[ -n "$WEB_NODE" ] || fail "no node labeled pool.synorg.io/name=web"

cap="$(gpu_allocatable "$WARM_NODE")"
{ [ -n "$cap" ] && [ "$cap" != "0" ]; } || fail "$WARM_NODE (warm-floor) advertises no nvidia.com/gpu"
[ "$(taint_effect "$WARM_NODE" pool.synorg.io/warm-floor)" = "NoSchedule" ] \
  || fail "$WARM_NODE missing taint pool.synorg.io/warm-floor=true:NoSchedule"
pass "warm-floor node $WARM_NODE: nvidia.com/gpu=$cap, warm-floor taint present"

cap="$(gpu_allocatable "$LEND_NODE")"
{ [ -n "$cap" ] && [ "$cap" != "0" ]; } || fail "$LEND_NODE (lendable) advertises no nvidia.com/gpu"
[ "$(taint_effect "$LEND_NODE" pool.synorg.io/lendable)" = "NoSchedule" ] \
  || fail "$LEND_NODE missing taint pool.synorg.io/lendable=true:NoSchedule"
pass "lendable node $LEND_NODE: nvidia.com/gpu=$cap, lendable taint present"

cap="$(gpu_allocatable "$WEB_NODE")"
{ [ -z "$cap" ] || [ "$cap" = "0" ]; } || fail "$WEB_NODE (web) must not advertise nvidia.com/gpu (has $cap)"
[ -z "$(k get node "$WEB_NODE" -o jsonpath='{.spec.taints[?(@.key=="pool.synorg.io/warm-floor")].key}{.spec.taints[?(@.key=="pool.synorg.io/lendable")].key}')" ] \
  || fail "$WEB_NODE (web) must carry no GPU pool taints"
pass "web node $WEB_NODE: no GPU capacity, no pool taints"

# --- 2. ValidatingAdmissionPolicy v1 served ----------------------------------
k api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
  | grep -q '^validatingadmissionpolicies\.' \
  || fail "ValidatingAdmissionPolicy v1 not served (node image must be k8s >= 1.30)"
pass "admissionregistration.k8s.io/v1 ValidatingAdmissionPolicy served"

# --- 3+4. Probe pods ---------------------------------------------------------
k get namespace "$PROBE_NS" >/dev/null 2>&1 || fail "namespace $PROBE_NS missing — up.sh creates it"
cleanup_probes() {
  k -n "$PROBE_NS" delete pod gpu-probe cpu-probe --ignore-not-found --now >/dev/null 2>&1 || true
}
trap cleanup_probes EXIT
cleanup_probes

# GPU probe: requests nvidia.com/gpu and is policy-compliant — carries
# team.synorg.io/name (require-team-label denies GPU pods without it) and the
# legitimate training-on-lendable combination (tenancy-guard bars training from
# warm-floor and customer-data from lendable).
k apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-probe
  namespace: $PROBE_NS
  labels:
    team.synorg.io/name: platform-harness
    workload.synorg.io/class: training
spec:
  restartPolicy: Never
  nodeSelector:
    pool.synorg.io/name: lendable
  tolerations:
    - key: pool.synorg.io/lendable
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: probe
      image: registry.k8s.io/pause:3.10
      resources:
        requests:
          nvidia.com/gpu: "1"
        limits:
          nvidia.com/gpu: "1"
EOF
k -n "$PROBE_NS" wait pod/gpu-probe --for=condition=PodScheduled --timeout=120s \
  || fail "GPU probe pod never scheduled (mode: $GPU_MODE)"
k -n "$PROBE_NS" wait pod/gpu-probe --for=condition=Ready --timeout=240s \
  || fail "GPU probe pod scheduled but never became Ready (mode: $GPU_MODE)"
node="$(k -n "$PROBE_NS" get pod gpu-probe -o jsonpath='{.spec.nodeName}')"
[ "$(k get node "$node" -o jsonpath='{.metadata.labels.pool\.synorg\.io/name}')" = "lendable" ] \
  || fail "GPU probe landed on '$node', not a lendable-pool node"
pass "GPU probe scheduled + Ready on real lendable worker $node"

# Non-GPU probe: no tolerations, no selector — the only schedulable node is the
# untainted web worker (control-plane and GPU pools are tainted).
k apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cpu-probe
  namespace: $PROBE_NS
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: registry.k8s.io/pause:3.10
EOF
k -n "$PROBE_NS" wait pod/cpu-probe --for=condition=Ready --timeout=120s \
  || fail "non-GPU probe pod never became Ready"
node="$(k -n "$PROBE_NS" get pod cpu-probe -o jsonpath='{.spec.nodeName}')"
[ "$(k get node "$node" -o jsonpath='{.metadata.labels.pool\.synorg\.io/name}')" = "web" ] \
  || fail "non-GPU probe landed on '$node' — plain pods must stay off GPU nodes"
pass "non-GPU probe Ready on web worker $node"

echo
echo "VERIFY OK (GPU mode: $GPU_MODE)"
