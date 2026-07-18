#!/usr/bin/env bash
# karpenter_test.sh — Karpenter-core lifecycle ladder on the ISOLATED kwok
# cluster (tests/kind/kwok-up.sh). Formerly scheduling_test.sh s6: a live
# Karpenter controller garbage-collects the main harness's real workers
# (karpenter.sh/nodepool labels with no backing cloudprovider instance), so
# the kwok/Karpenter coverage runs against its own tiny cluster — this suite
# must NEVER be pointed at the main harness cluster.
#
# All scenarios run on kwok VIRTUAL nodes: no kubelet, pods bound there never
# run. The assertions are about Karpenter's provider-agnostic core
# (provisioning, consolidation, drift), never workload execution.
#   s1_provision      a pending Deployment that tolerates the virtual taint
#                     makes NodePool kwok-test provision a node carrying the
#                     template taints, and the pod binds to it
#   s2_consolidation  deleting the workload lets WhenEmptyOrUnderutilized
#                     remove the empty node and its NodeClaim
#   s3_drift          a NodePool template label change REPLACES the live
#                     NodeClaim (old gone, successor provisioned); the
#                     template is restored by the cleanup trap
#
# Usage:
#   karpenter_test.sh             run every scenario (Makefile kwok phase)
#   karpenter_test.sh --list      enumerate scenario names
#   karpenter_test.sh <scenario>  run one scenario (independently runnable)
#   karpenter_test.sh --lint      offline checks, no cluster: yq cross-checks
#                                 tests/kind/karpenter-kwok.yaml against the
#                                 names/taints this script and its workload pin
#
# Env:
#   KWOK_TEST_CONTEXT   kube context (default kind-synorg-kwok)
#
# Style follows tests/integration/scheduling/scheduling_test.sh: need/fail
# helpers, set -euo pipefail, bounded waits only, trap-based cleanup that
# restores the NodePool template and deletes test workloads. Every assertion
# checks a SPECIFIC condition (node taints, NodeClaim names, pod binding) —
# never a bare exit code (R6: a vacuous pass is a defect).
#
# shellcheck disable=SC2329  # predicate functions are invoked indirectly via wait_for "$@"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
KWOK_YAML="$ROOT/tests/kind/karpenter-kwok.yaml"
WORKLOAD="$HERE/workloads/kwok-deployment.yaml"

KCTX="${KWOK_TEST_CONTEXT:-kind-synorg-kwok}"
KWOK_NODEPOOL="kwok-test"                    # tests/kind/karpenter-kwok.yaml (--lint cross-checks)
VIRTUAL_TAINT="karpenter.kwok.sh/virtual"    # NodePool template taint key
TEST_NS="kwok-test"                          # namespace pinned in workloads/kwok-deployment.yaml

WAIT_KWOK=420        # Karpenter provision/consolidate/drift round trip
WAIT_RESET=180       # substrate teardown between scenarios

SCENARIOS=(
  s1_provision
  s2_consolidation
  s3_drift
)

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so local runs match CI"; }
k()    { kubectl --context "$KCTX" "$@"; }

# wait_for SECONDS DESCRIPTION CMD... — poll CMD until true or timeout. The
# only wait primitive in this file: every wait is bounded, none is a bare
# `kubectl wait` without --timeout.
wait_for() {
  local t="$1" desc="$2"; shift 2
  local elapsed=0
  until "$@"; do
    elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$t" ]; then
      echo "TIMEOUT after ${t}s waiting for: $desc" >&2
      return 1
    fi
    sleep 3
  done
}

# --- kwok substrate predicates ----------------------------------------------
KWOK_SEL="karpenter.sh/nodepool=$KWOK_NODEPOOL"
kwok_nodeclaims() { k get nodeclaims -l "$KWOK_SEL" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true; }
kwok_nodeclaim_exists() { [ -n "$(kwok_nodeclaims)" ]; }
kwok_node_exists() { [ -n "$(k get nodes -l "$KWOK_SEL" -o name 2>/dev/null)" ]; }
kwok_substrate_empty() { [ -z "$(kwok_nodeclaims)" ] && ! kwok_node_exists; }
kwok_pod_bound() { [ -n "$(k -n "$TEST_NS" get pods -l app=kwok-probe -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)" ]; }

deploy_probe() {
  k apply -f "$WORKLOAD" >/dev/null
  echo "  submitted kwok-probe deployment (tolerates $VIRTUAL_TAINT, pins nodepool=$KWOK_NODEPOOL)"
}

# reset_substrate — start each scenario from zero virtual nodes, so its
# provisioning assertion is about THIS scenario's demand, never a leftover.
reset_substrate() {
  k -n "$TEST_NS" delete deployment kwok-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k delete nodeclaims -l "$KWOK_SEL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  wait_for "$WAIT_RESET" "kwok substrate empty before scenario" kwok_substrate_empty \
    || fail "could not reach an empty kwok substrate before the scenario"
}

# --- lifecycle ---------------------------------------------------------------

preflight() {
  need kubectl
  if ! k get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
    cat >&2 <<EOF
================================================================================
 SKIP (LOUD): the isolated kwok/Karpenter cluster is UNREACHABLE.
 No cluster answers at context '$KCTX' — Karpenter-core
 provisioning/consolidation/drift semantics are NOT being tested.
 Bring it up first:  bash tests/kind/kwok-up.sh
 (or point KWOK_TEST_CONTEXT at an existing kwok cluster)
================================================================================
EOF
    exit 77
  fi
  k get crd nodepools.karpenter.sh >/dev/null 2>&1 \
    || fail "NodePool CRD missing in context '$KCTX' — kwok-up.sh did not complete (re-run it)"
  k get nodepool "$KWOK_NODEPOOL" >/dev/null 2>&1 \
    || fail "NodePool '$KWOK_NODEPOOL' missing in context '$KCTX' — kwok-up.sh applies tests/kind/karpenter-kwok.yaml (re-run it)"
}

ensure_ns() {
  k create namespace "$TEST_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# cleanup — EXIT trap: restore the NodePool template, delete the probe
# workload; the top-level (non-child) run also clears leftover NodeClaims and
# drops the test namespace.
cleanup() {
  local rc=$?
  set +e
  trap - EXIT
  if [ "${DRIFT_PATCHED:-0}" = "1" ]; then
    k patch nodepool "$KWOK_NODEPOOL" --type=json \
      -p '[{"op":"remove","path":"/spec/template/metadata/labels/synorg-drift-test"}]' >/dev/null 2>&1 \
      || echo "WARN: failed to remove drift-test label from NodePool $KWOK_NODEPOOL — restore it: kubectl --context $KCTX apply -f $KWOK_YAML" >&2
  fi
  k -n "$TEST_NS" delete deployment kwok-probe --ignore-not-found --wait=false >/dev/null 2>&1
  if [ "${KWOK_TEST_CHILD:-0}" != "1" ]; then
    k delete nodeclaims -l "$KWOK_SEL" --ignore-not-found --wait=false >/dev/null 2>&1
    k delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  exit "$rc"
}

# --- scenarios ---------------------------------------------------------------

# s1: provisioning — a pending toleration-matched pod makes the NodePool
# provision a node carrying the template taints, and the pod binds to it.
scenario_s1_provision() {
  reset_substrate
  deploy_probe
  wait_for "$WAIT_KWOK" "NodeClaim for NodePool $KWOK_NODEPOOL" kwok_nodeclaim_exists
  wait_for "$WAIT_KWOK" "kwok node registered" kwok_node_exists
  local node taint_val
  node="$(k get nodes -l "$KWOK_SEL" -o jsonpath='{.items[0].metadata.name}')"
  taint_val="$(k get node "$node" -o jsonpath="{.spec.taints[?(@.key==\"$VIRTUAL_TAINT\")].value}")"
  [ "$taint_val" = "true" ] || fail "provisioned kwok node $node lacks the template taint $VIRTUAL_TAINT=true (got '$taint_val')"
  wait_for "$WAIT_KWOK" "kwok-probe pod bound to a node" kwok_pod_bound
  local bound
  bound="$(k -n "$TEST_NS" get pods -l app=kwok-probe -o jsonpath='{.items[0].spec.nodeName}')"
  [ "$(k get node "$bound" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')" = "$KWOK_NODEPOOL" ] \
    || fail "kwok-probe bound to '$bound', which is not a $KWOK_NODEPOOL node"
  echo "  provision OK: node $node carries the virtual taint, pod bound to the pool"
}

# s2: consolidation — delete the workload; WhenEmptyOrUnderutilized
# (consolidateAfter 10s) must remove the now-empty node and its NodeClaim.
scenario_s2_consolidation() {
  reset_substrate
  deploy_probe
  wait_for "$WAIT_KWOK" "NodeClaim provisioned for consolidation test" kwok_nodeclaim_exists
  wait_for "$WAIT_KWOK" "kwok-probe pod bound" kwok_pod_bound
  k -n "$TEST_NS" delete deployment kwok-probe --wait=false >/dev/null
  echo "  deleted kwok-probe — the virtual node is now empty"
  wait_for "$WAIT_KWOK" "empty kwok node consolidated away" kwok_substrate_empty
  echo "  consolidation OK: empty node and its NodeClaim removed"
}

# s3: drift — with demand present, a NodePool template change must REPLACE the
# nodeclaim (old gone, new one provisioned). Template restored by the trap.
scenario_s3_drift() {
  reset_substrate
  deploy_probe
  wait_for "$WAIT_KWOK" "NodeClaim provisioned for drift test" kwok_nodeclaim_exists
  local nc1
  nc1="$(k get nodeclaims -l "$KWOK_SEL" -o jsonpath='{.items[0].metadata.name}')"
  DRIFT_PATCHED=1
  k patch nodepool "$KWOK_NODEPOOL" --type=merge \
    -p '{"spec":{"template":{"metadata":{"labels":{"synorg-drift-test":"v2"}}}}}' >/dev/null
  echo "  patched NodePool $KWOK_NODEPOOL template (label synorg-drift-test=v2) — expecting drift replacement of $nc1"
  drift_replaced() {
    local names; names="$(kwok_nodeclaims)"
    [ -n "$names" ] || return 1
    case " $names " in *" $nc1 "*) return 1 ;; esac
    return 0
  }
  wait_for "$WAIT_KWOK" "nodeclaim $nc1 replaced by a drifted successor" drift_replaced
  echo "  drift OK: $nc1 replaced by $(kwok_nodeclaims) after template change"
}

# --- offline lint (--lint): no cluster required ------------------------------
# yq cross-checks the manifest triangle this suite depends on: karpenter-kwok
# .yaml (NodePool + KWOKNodeClass) <-> this script's pinned names <-> the
# probe workload's selector/toleration. A drift in any corner fails here,
# offline, before a cluster is ever created.
run_lint() {
  need yq
  local rc=0
  lint_err() { echo "LINT FAIL: $*" >&2; rc=1; }

  [ -f "$KWOK_YAML" ] || fail "lint: $KWOK_YAML missing"
  [ -f "$WORKLOAD" ] || fail "lint: $WORKLOAD missing"
  echo "lint: $KWOK_YAML <-> $(basename "$WORKLOAD") <-> script pins"

  local np nc ncref_name ncref_group taint_key taint_effect policy
  np="$(yq -N 'select(.kind=="NodePool") | .metadata.name' "$KWOK_YAML")"
  nc="$(yq -N 'select(.kind=="KWOKNodeClass") | .metadata.name' "$KWOK_YAML")"
  ncref_name="$(yq -N 'select(.kind=="NodePool") | .spec.template.spec.nodeClassRef.name' "$KWOK_YAML")"
  ncref_group="$(yq -N 'select(.kind=="NodePool") | .spec.template.spec.nodeClassRef.group' "$KWOK_YAML")"
  taint_key="$(yq -N 'select(.kind=="NodePool") | .spec.template.spec.taints[0].key' "$KWOK_YAML")"
  taint_effect="$(yq -N 'select(.kind=="NodePool") | .spec.template.spec.taints[0].effect' "$KWOK_YAML")"
  policy="$(yq -N 'select(.kind=="NodePool") | .spec.disruption.consolidationPolicy' "$KWOK_YAML")"

  [ "$np" = "$KWOK_NODEPOOL" ] || lint_err "NodePool name '$np' != script pin '$KWOK_NODEPOOL'"
  [ "$nc" = "$ncref_name" ] || lint_err "NodePool nodeClassRef.name '$ncref_name' != KWOKNodeClass '$nc'"
  [ "$ncref_group" = "karpenter.kwok.sh" ] || lint_err "nodeClassRef.group '$ncref_group' != karpenter.kwok.sh"
  [ "$taint_key" = "$VIRTUAL_TAINT" ] || lint_err "template taint key '$taint_key' != script pin '$VIRTUAL_TAINT'"
  [ "$taint_effect" = "NoSchedule" ] || lint_err "template taint effect '$taint_effect' != NoSchedule"
  case "$policy" in
    WhenEmpty|WhenEmptyOrUnderutilized) ;;
    *) lint_err "consolidationPolicy '$policy' would never remove the emptied node (s2_consolidation)" ;;
  esac

  local w_ns w_sel w_tol_key w_app
  w_ns="$(yq -N '.metadata.namespace' "$WORKLOAD")"
  w_sel="$(yq -N '.spec.template.spec.nodeSelector."karpenter.sh/nodepool"' "$WORKLOAD")"
  w_tol_key="$(yq -N '.spec.template.spec.tolerations[0].key' "$WORKLOAD")"
  w_app="$(yq -N '.spec.selector.matchLabels.app' "$WORKLOAD")"
  [ "$w_ns" = "$TEST_NS" ] || lint_err "workload namespace '$w_ns' != script pin '$TEST_NS'"
  [ "$w_sel" = "$np" ] || lint_err "workload nodeSelector pins nodepool '$w_sel' != NodePool '$np'"
  [ "$w_tol_key" = "$taint_key" ] || lint_err "workload toleration key '$w_tol_key' does not match the template taint '$taint_key'"
  [ "$w_app" = "kwok-probe" ] || lint_err "workload selector app '$w_app' != kwok-probe (the substrate predicates select app=kwok-probe)"

  [ "$rc" -eq 0 ] || exit 1
  echo "LINT OK: karpenter-kwok.yaml, $(basename "$WORKLOAD"), and script pins are mutually consistent"
}

# --- entry points ------------------------------------------------------------

run_one() {
  local s="$1" known=0 x
  for x in "${SCENARIOS[@]}"; do [ "$x" = "$s" ] && known=1; done
  [ "$known" = 1 ] || fail "unknown scenario '$s' — see: $0 --list"
  preflight
  trap cleanup EXIT
  ensure_ns
  "scenario_$s"
  echo "PASS: $s"
}

run_all() {
  preflight
  trap cleanup EXIT
  ensure_ns
  local pass=0 failn=0 failed="" s rc
  for s in "${SCENARIOS[@]}"; do
    echo
    echo "=== scenario: $s ==="
    rc=0
    # Each scenario runs as its own process: set -e stays honest inside the
    # scenario (no if-context errexit suppression) and its trap cleans its own
    # workload before the next scenario starts.
    KWOK_TEST_CHILD=1 bash "$SELF" "$s" || rc=$?
    case "$rc" in
      0)  pass=$((pass + 1)) ;;
      *)  failn=$((failn + 1)); failed="$failed $s"; echo "FAIL: $s (exit $rc)" ;;
    esac
  done
  echo
  echo "kwok/karpenter ladder: $pass passed, $failn failed${failed:+ —$failed}"
  [ "$failn" -eq 0 ]
}

case "${1:-}" in
  --list) printf '%s\n' "${SCENARIOS[@]}" ;;
  --lint) run_lint ;;
  -h|--help)
    sed -n '2,37p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  "") run_all ;;
  *)  run_one "$1" ;;
esac
