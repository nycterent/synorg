#!/usr/bin/env bash
# kwok-up.sh — bring up the ISOLATED kwok/Karpenter cluster: a tiny ephemeral
# kind cluster (kwok-cluster.yaml, single control-plane node) running kwok +
# the Karpenter kwok provider, plus the test-only kwok-test NodePool
# (karpenter-kwok.yaml). Exercised by tests/kwok/karpenter_test.sh; torn down
# by kwok-down.sh. Idempotent: re-running against an existing cluster is safe.
#
# Why a separate cluster from up.sh (validated live, runs 6-9): a live
# Karpenter controller garbage-collects the main harness's workers — they
# carry karpenter.sh/nodepool labels (required so the unmodified Kueue
# ResourceFlavors bind; KTD2, the labels cannot be removed) but have no
# backing instance in Karpenter's cloudprovider list, so leaked-node GC
# cordons them and kills the scheduling scenarios. The main harness therefore
# never installs Karpenter; it lives here, alone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# --- Pinned versions (see tests/kind/README.md pin table) --------------------
KWOK_VERSION="v0.8.0"                # kwok node simulator (stages + controller)
KARPENTER_VERSION="v1.14.0"          # sigs.k8s.io/karpenter (kwok provider, built from source)
KO_VERSION="v0.19.1"                 # ko, builds the kwok controller image into kind

CLUSTER_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$HERE/kwok-cluster.yaml")"
KCTX="kind-${CLUSTER_NAME}"

# --- Helpers (self-contained copy of up.sh's — tiers stay standalone) --------
fail() { echo "KWOK-UP FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) before bringing the kwok cluster up"; }
step() { echo; echo "==> $*"; }
# All kubectl calls target the kwok context explicitly so the user's current
# context is never assumed or clobbered.
k() { kubectl --context "$KCTX" "$@"; }

usage() {
  # Print the header comment block (everything up to the first non-comment line).
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) fail "unknown flag: $1 (see --help)" ;;
esac

# --- Preflight ---------------------------------------------------------------
need kind
need docker
need kubectl
need helm
# go + git are HARD requirements here (unlike the main harness): the Karpenter
# kwok provider has no published controller image and is built from a pinned
# source checkout with ko. Failing loudly beats skipping silently (R6).
need go
need git
docker info >/dev/null 2>&1 || fail "docker daemon is not running — start Docker Desktop (or colima) first"
[ -n "$CLUSTER_NAME" ] || fail "could not read cluster name from $HERE/kwok-cluster.yaml"

# --- 1. Cluster --------------------------------------------------------------
step "kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "cluster already exists — reusing (idempotent re-run)"
else
  kind create cluster --config "$HERE/kwok-cluster.yaml" --wait 120s
fi
k get nodes >/dev/null || fail "cluster '$CLUSTER_NAME' is not reachable via context $KCTX"

# --- 2. kwok + Karpenter kwok provider ---------------------------------------
step "kwok $KWOK_VERSION + karpenter kwok provider $KARPENTER_VERSION"
k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"

src="$ROOT/build/karpenter-kwok/karpenter-${KARPENTER_VERSION}"
if [ ! -d "$src" ]; then
  mkdir -p "$(dirname "$src")"
  git clone --quiet --depth 1 --branch "$KARPENTER_VERSION" \
    https://github.com/kubernetes-sigs/karpenter "$src"
fi

# --platform must match the kind node's architecture — ko defaults to
# linux/amd64, which yields a 0/1 CrashLoop (exec format) on arm64 hosts.
arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)"
case "$arch" in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
img="$(cd "$src" && KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" \
  go run "github.com/google/ko@${KO_VERSION}" build -B --platform="linux/${arch}" sigs.k8s.io/karpenter/kwok)"
# ko prints REPO[:TAG]@DIGEST; split it the same way upstream's Makefile does.
repo="$(echo "$img" | cut -d '@' -f 1 | cut -d ':' -f 1)"
tag="$(echo "$img" | cut -d '@' -f 1 | cut -d ':' -f 2 -s)"
digest="$(echo "$img" | cut -d '@' -f 2 -s)"

k apply --server-side --force-conflicts -f "$src/kwok/charts/crds"
# The control-plane is the ONLY real node in this cluster, so the controller
# must tolerate its taint — REQUIRED here, not belt-and-braces. (The chart's
# node affinity forbids nodes carrying karpenter.sh/nodepool, which is every
# kwok virtual node, so nothing else could ever host it.)
helm --kube-context "$KCTX" upgrade --install karpenter "$src/kwok/charts" \
  --namespace kube-system --skip-crds \
  --set controller.image.repository="$repo" \
  --set controller.image.tag="${tag:-latest}" \
  --set controller.image.digest="$digest" \
  --set-json 'tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists"},{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]' \
  --set settings.featureGates.staticCapacity=false \
  --set settings.featureGates.capacityBuffer=false \
  --wait --timeout 5m
# ^ staticCapacity/capacityBuffer: the v1.14.0 chart's FEATURE_GATES template
# references both but values.yaml defines neither — unset they render empty
# and the controller panics at boot ("invalid value of StaticCapacity").

# --- 3. Test-only NodePool + KWOKNodeClass -----------------------------------
# Tainted NodePool + KWOKNodeClass: virtual nodes for the provisioning /
# consolidation / drift suite, unreachable by anything without an explicit
# karpenter.kwok.sh/virtual toleration.
step "apply karpenter-kwok.yaml (kwok-test NodePool + KWOKNodeClass)"
k apply -f "$HERE/karpenter-kwok.yaml"

echo
echo "kwok cluster up: '$CLUSTER_NAME' (context $KCTX) — run: bash tests/kwok/karpenter_test.sh"
