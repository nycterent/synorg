#!/usr/bin/env bash
# scheduling_test.sh — U3 integration ladder: Kueue quota/preemption semantics
# of the GPU-lending design (KTD6) on the kind harness (tests/kind/up.sh).
#
# Proven against a REAL Kueue (v0.18) with RUNNING fake-GPU pods:
#   s1_borrow_within_limit           training admits while within training-borrow's
#                                    borrowingLimit; pods run on the real lendable worker
#   s2_blocked_past_limit            a workload past the limit stays Pending
#                                    (Workload QuotaReserved/Admitted != True, job suspended)
#   s3_shrink_limit_stops_admission  shrinking the limit (kubectl patch ClusterQueue —
#                                    the same write surface the U4 lending controller
#                                    uses) stops NEW admission; restoring resumes it
#   s4_inference_preempts_training   a pending inference-critical pod preempts a
#                                    training-preemptible pod node-level: REAL eviction,
#                                    valid because fake-GPU pods actually run (R1/KTD6)
#   s5_warm_floor_taint_blocks_training  training tolerations cannot land on a
#                                    warm-floor node (pool taint, R12 containment)
#   s6_karpenter_kwok_lifecycle      Karpenter core on the kwok virtual substrate:
#                                    provision (taints), consolidation (empty node),
#                                    drift (template change replaces nodeclaim).
#                                    Skipped LOUDLY when kwok is absent (up.sh --no-kwok)
#   s7_tas_hot_swap                  out of scope on kind — explicit SKIP note
#
# Usage:
#   scheduling_test.sh              run every scenario (Makefile `integration` entry)
#   scheduling_test.sh --list       enumerate scenario names
#   scheduling_test.sh <scenario>   run one scenario (independently runnable)
#   scheduling_test.sh --lint       offline checks, no cluster: kubeconform on
#                                   workloads/ + queue/flavor/priority-class name
#                                   consistency against clusters/pilot/kueue/
#
# Env:
#   SCHEDULING_TEST_CONTEXT    kube context (default kind-synorg)
#   SCHEDULING_TEST_WORKLOADS  workloads dir override (lint self-tests only)
#
# Style follows scripts/validate.sh: need/fail helpers, set -euo pipefail,
# timeouts on every wait (no infinite kubectl wait), trap-based cleanup that
# restores ClusterQueue values and deletes test workloads/namespaces. Every
# assertion checks a SPECIFIC condition (Workload .status.conditions, pod
# phase/conditions, node taints) — never a bare exit code (R6: a vacuous pass
# is a defect).
#
# shellcheck disable=SC2329  # predicate functions are invoked indirectly via wait_for "$@"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
WORKLOADS="${SCHEDULING_TEST_WORKLOADS:-$HERE/workloads}"
KUEUE_DIR="$ROOT/clusters/pilot/kueue"

KCTX="${SCHEDULING_TEST_CONTEXT:-kind-synorg}"
K8S_VERSION="1.33.0"                # matches the pin in scripts/validate.sh

# Exact object names — cross-checked against clusters/pilot/kueue/ by --lint.
CQ="training-borrow"                # ClusterQueue training borrows through (KTD6)
LQ="team-ml"                        # pilot LocalQueue (conventions.md: team-<name>)
TEAM_NS="team-ml"                   # LocalQueue namespace == team namespace
FLAVOR="gpu-lendable"               # the only flavor training has quota on
PC_INFERENCE="inference-critical"   # emergency-preempts training (R1)
PC_TRAINING="training-preemptible"  # preemptible, never preempts (KTD12)
KWOK_NODEPOOL="kwok-test"           # tests/kind/karpenter-kwok.yaml

TEST_NS="scheduling-test"           # non-Kueue test pods (inference probe, kwok)
LABEL_KEY="synorg.io/scheduling-test"
SEL="$LABEL_KEY=true"

WAIT_ADMIT=90        # Kueue admission round trip
WAIT_POD=240         # pod Running (first run pays the pause-image pull)
WAIT_PREEMPT=180     # kube-scheduler preemption + victim teardown
WAIT_KWOK=420        # Karpenter provision/consolidate/drift on kwok
HOLD_PENDING=30      # observation window proving a workload is NOT admitted

SCENARIOS=(
  s1_borrow_within_limit
  s2_blocked_past_limit
  s3_shrink_limit_stops_admission
  s4_inference_preempts_training
  s5_warm_floor_taint_blocks_training
  s6_karpenter_kwok_lifecycle
  s7_tas_hot_swap
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

# --- Kueue predicates (specific conditions, never exit codes) ---------------

# wl_of_job JOB — name of the Workload object Kueue created for the Job.
wl_of_job() {
  k -n "$TEAM_NS" get workloads -o json 2>/dev/null \
    | jq -r --arg j "$1" \
        '(first(.items[] | select(.metadata.ownerReferences[]? | (.kind=="Job" and .name==$j)) | .metadata.name)) // ""'
}

wl_exists() { [ -n "$(wl_of_job "$1")" ]; }

# wl_cond WORKLOAD TYPE — status ("True"/"False"/"") of a Workload condition.
wl_cond() {
  k -n "$TEAM_NS" get workload "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}" 2>/dev/null || true
}

# job_admitted JOB — the Workload's Admitted condition is True.
job_admitted() {
  local wl; wl="$(wl_of_job "$1")"
  [ -n "$wl" ] || return 1
  [ "$(wl_cond "$wl" Admitted)" = "True" ]
}

job_suspend() { k -n "$TEAM_NS" get job "$1" -o jsonpath='{.spec.suspend}' 2>/dev/null || true; }

pod_of_job() { k -n "$TEAM_NS" get pods -l job-name="$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }

pod_running() { [ "$(k -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; }

job_pod_running() {
  local p; p="$(pod_of_job "$1")"
  [ -n "$p" ] && pod_running "$TEAM_NS" "$p"
}

# assert_pod_on_lendable NS POD — bound to the REAL lendable worker (pool label
# from docs/conventions.md), never a kwok virtual node (kwok nodes carry no
# pool.synorg.io/name label).
assert_pod_on_lendable() {
  local node pool
  node="$(k -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}')"
  [ -n "$node" ] || fail "pod $2 has no nodeName"
  pool="$(k get node "$node" -o jsonpath='{.metadata.labels.pool\.synorg\.io/name}')"
  [ "$pool" = "lendable" ] || fail "pod $2 landed on node '$node' (pool '$pool') — expected the REAL lendable worker"
  echo "  pod $2 bound to real lendable node $node"
}

# --- ClusterQueue borrowingLimit read/patch ---------------------------------
# Index paths are guarded by preflight (flavor[0] must be gpu-lendable). The
# patch is deliberately the same write surface the U4 lending controller uses.
cq_limit() { k get clusterqueue "$CQ" -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].borrowingLimit}'; }
cq_set_limit() {
  k patch clusterqueue "$CQ" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/resourceGroups/0/flavors/0/resources/0/borrowingLimit\",\"value\":$1}]" >/dev/null
}

# begin_cq_window — save the live borrowingLimit and pin it to the physical
# GPU capacity of the lendable worker, so "up to the limit" jobs actually RUN
# (the manifest placeholder 64 exceeds what fake-gpu-operator advertises).
# The saved value is restored by the cleanup trap.
begin_cq_window() {
  CQ_ORIG_LIMIT="$(cq_limit)"
  case "$CQ_ORIG_LIMIT" in ''|*[!0-9]*) fail "cannot read $CQ borrowingLimit (got '$CQ_ORIG_LIMIT')";; esac
  cq_set_limit "$GPU_CAP"
  echo "  $CQ borrowingLimit: $CQ_ORIG_LIMIT -> $GPU_CAP (test window; restored on exit)"
}

# --- Workload rendering (yq over templates in workloads/) -------------------

# render_training_job NAME GPUS — instantiate the training Job template. Kueue
# injects the gpu-lendable flavor's nodeSelector + tolerations on admission,
# which is exactly the binding-to-real-workers behavior under test.
render_training_job() {
  yq ".metadata.name = \"$1\"
      | .spec.template.spec.containers[0].resources.requests.\"nvidia.com/gpu\" = \"$2\"
      | .spec.template.spec.containers[0].resources.limits.\"nvidia.com/gpu\" = \"$2\"" \
    "$WORKLOADS/training-job.yaml"
}

apply_training_job() { # NAME GPUS
  render_training_job "$1" "$2" | k apply -f - >/dev/null
  echo "  submitted training job $1 (${2} GPU) to LocalQueue $LQ"
}

# render_gpu_pod FILE NAME GPUS — instantiate a bare-Pod template (inference /
# warm-floor probes; these never pass Kueue — KTD6).
render_gpu_pod() {
  yq ".metadata.name = \"$2\"
      | .spec.containers[0].resources.requests.\"nvidia.com/gpu\" = \"$3\"
      | .spec.containers[0].resources.limits.\"nvidia.com/gpu\" = \"$3\"" "$1"
}

# --- lifecycle ---------------------------------------------------------------

preflight() {
  need kubectl; need jq; need yq
  k get --raw /readyz --request-timeout=10s >/dev/null 2>&1 \
    || fail "cluster context '$KCTX' unreachable — bring the harness up (tests/kind/up.sh) or set SCHEDULING_TEST_CONTEXT"
  k get clusterqueue "$CQ" >/dev/null 2>&1 \
    || fail "ClusterQueue '$CQ' not found — U1 applies clusters/pilot/kueue/ (re-run tests/kind/up.sh)"
  k -n "$TEAM_NS" get localqueue "$LQ" >/dev/null 2>&1 \
    || fail "LocalQueue '$LQ' in ns '$TEAM_NS' not found — U1 applies clusters/pilot/kueue/"
  [ "$(k get clusterqueue "$CQ" -o jsonpath='{.spec.resourceGroups[0].flavors[0].name}')" = "$FLAVOR" ] \
    || fail "ClusterQueue $CQ flavor[0] is not '$FLAVOR' — the borrowingLimit patch paths here assume it"
  # Size requests to what the lendable worker really advertises (GPU_COUNT in
  # tests/kind/up.sh, default 8) instead of hardcoding it.
  GPU_CAP="$(k get nodes -l pool.synorg.io/name=lendable -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)" || true
  case "$GPU_CAP" in ''|*[!0-9]*) fail "lendable worker advertises no nvidia.com/gpu — fake-gpu-operator not ready (tests/kind/up.sh)";; esac
  [ "$GPU_CAP" -ge 2 ] || fail "need >=2 GPUs on the lendable worker to split quota (got $GPU_CAP)"
  HALF=$((GPU_CAP / 2))
}

ensure_ns() {
  k create namespace "$TEST_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# cleanup — EXIT trap: restore ClusterQueue values and the kwok NodePool
# template, delete test workloads, wait for pod teardown (so back-to-back
# scenarios start with free GPU capacity), drop the test namespace.
cleanup() {
  local rc=$?
  set +e
  trap - EXIT
  if [ "${DRIFT_PATCHED:-0}" = "1" ]; then
    k patch nodepool "$KWOK_NODEPOOL" --type=json \
      -p '[{"op":"remove","path":"/spec/template/metadata/labels/synorg-drift-test"}]' >/dev/null 2>&1 \
      || echo "WARN: failed to remove drift-test label from NodePool $KWOK_NODEPOOL" >&2
  fi
  if [ -n "${CQ_ORIG_LIMIT:-}" ]; then
    cq_set_limit "$CQ_ORIG_LIMIT" \
      || echo "WARN: failed to restore $CQ borrowingLimit=$CQ_ORIG_LIMIT — restore it by re-applying $KUEUE_DIR" >&2
  fi
  k -n "$TEAM_NS" delete jobs -l "$SEL" --ignore-not-found --wait=false >/dev/null 2>&1
  k -n "$TEST_NS" delete deployments,pods -l "$SEL" --ignore-not-found --wait=false >/dev/null 2>&1
  local elapsed=0
  while [ -n "$(k -n "$TEAM_NS" get pods -l "$SEL" -o name 2>/dev/null)" ] \
     || [ -n "$(k -n "$TEST_NS" get pods -l "$SEL" -o name 2>/dev/null)" ]; do
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge 90 ]; then
      echo "WARN: test pods still terminating after 90s" >&2
      break
    fi
    sleep 2
  done
  if [ "${SCHEDULING_TEST_CHILD:-0}" != "1" ]; then
    k delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  exit "$rc"
}

# assert_held_pending JOB LIMIT_DESC — prove the job is being HELD by quota:
# watch for HOLD_PENDING seconds that it never admits, then pin the specific
# conditions (Workload QuotaReserved != True, Job still suspended).
assert_held_pending() {
  local j="$1" why="$2" elapsed=0 wl qr adm
  wait_for 30 "Workload object for $j" wl_exists "$j" || fail "$j: Kueue never created a Workload"
  while [ "$elapsed" -lt "$HOLD_PENDING" ]; do
    job_admitted "$j" && fail "$j was ADMITTED — expected it held ($why)"
    sleep 3; elapsed=$((elapsed + 3))
  done
  wl="$(wl_of_job "$j")"
  qr="$(wl_cond "$wl" QuotaReserved)"
  adm="$(wl_cond "$wl" Admitted)"
  [ "$qr" != "True" ] || fail "$j Workload $wl has QuotaReserved=True ($why)"
  [ "$adm" != "True" ] || fail "$j Workload $wl has Admitted=True ($why)"
  [ "$(job_suspend "$j")" = "true" ] || fail "$j was unsuspended while $why"
  echo "  $j held for ${HOLD_PENDING}s: QuotaReserved='${qr:-<absent>}', Admitted='${adm:-<absent>}', job suspended ($why)"
}

# --- scenarios ---------------------------------------------------------------

# s1: two jobs that together exactly fill borrowingLimit are Admitted and their
# pods RUN on the real lendable worker (fake-GPU capacity is real to kubelet).
scenario_s1_borrow_within_limit() {
  begin_cq_window
  apply_training_job train-a "$HALF"
  apply_training_job train-b "$((GPU_CAP - HALF))"
  wait_for "$WAIT_ADMIT" "train-a Workload Admitted=True" job_admitted train-a
  wait_for "$WAIT_ADMIT" "train-b Workload Admitted=True" job_admitted train-b
  [ "$(job_suspend train-a)" = "false" ] || fail "train-a admitted but still suspended"
  [ "$(job_suspend train-b)" = "false" ] || fail "train-b admitted but still suspended"
  wait_for "$WAIT_POD" "train-a pod Running" job_pod_running train-a
  wait_for "$WAIT_POD" "train-b pod Running" job_pod_running train-b
  assert_pod_on_lendable "$TEAM_NS" "$(pod_of_job train-a)"
  assert_pod_on_lendable "$TEAM_NS" "$(pod_of_job train-b)"
  echo "  both jobs Admitted within borrowingLimit=$GPU_CAP and Running"
}

# s2: with the limit fully borrowed, one more job stays Pending.
scenario_s2_blocked_past_limit() {
  begin_cq_window
  apply_training_job train-a "$HALF"
  apply_training_job train-b "$((GPU_CAP - HALF))"
  wait_for "$WAIT_ADMIT" "train-a Workload Admitted=True" job_admitted train-a
  wait_for "$WAIT_ADMIT" "train-b Workload Admitted=True" job_admitted train-b
  apply_training_job train-c "$HALF"
  assert_held_pending train-c "past borrowingLimit=$GPU_CAP (already fully borrowed)"
}

# s3: shrink the limit (same kubectl-patch surface as the U4 controller) — new
# training stops admitting; restore — it admits. Bidirectional, so the pass
# can only come from the limit itself.
scenario_s3_shrink_limit_stops_admission() {
  begin_cq_window
  cq_set_limit 0
  echo "  $CQ borrowingLimit shrunk to 0 (controller write surface: kubectl patch clusterqueue)"
  apply_training_job train-d "$HALF"
  assert_held_pending train-d "borrowingLimit=0"
  cq_set_limit "$GPU_CAP"
  echo "  $CQ borrowingLimit restored to $GPU_CAP"
  wait_for "$WAIT_ADMIT" "train-d Workload Admitted=True after limit restore" job_admitted train-d
  echo "  train-d admitted after restore — admission was gated by the limit alone"
}

# s4: emergency reclaim (R1): a pending inference-critical pod preempts a
# RUNNING training-preemptible pod node-level via kube-scheduler — real
# eviction, no Kueue involvement (KTD6). Both pods pinned to the REAL lendable
# worker (pool labels/taints from docs/conventions.md), never kwok nodes.
scenario_s4_inference_preempts_training() {
  begin_cq_window
  apply_training_job train-e "$GPU_CAP"           # fill the node: preemption is the only way in
  wait_for "$WAIT_ADMIT" "train-e Workload Admitted=True" job_admitted train-e
  wait_for "$WAIT_POD" "train-e pod Running" job_pod_running train-e
  local victim victim_uid
  victim="$(pod_of_job train-e)"
  victim_uid="$(k -n "$TEAM_NS" get pod "$victim" -o jsonpath='{.metadata.uid}')"
  assert_pod_on_lendable "$TEAM_NS" "$victim"
  render_gpu_pod "$WORKLOADS/inference-pod.yaml" inference-probe "$HALF" | k apply -f - >/dev/null
  echo "  submitted inference-probe ($HALF GPU, PriorityClass $PC_INFERENCE) — node is full, must preempt"
  wait_for "$WAIT_PREEMPT" "inference-probe Running" pod_running "$TEST_NS" inference-probe
  assert_pod_on_lendable "$TEST_NS" inference-probe
  # The victim must be ACTUALLY evicted: gone, terminating, or carrying the
  # scheduler's DisruptionTarget/PreemptionByScheduler condition.
  local vjson cur_uid delts dreason
  vjson="$(k -n "$TEAM_NS" get pod "$victim" -o json 2>/dev/null || true)"
  if [ -n "$vjson" ]; then
    cur_uid="$(jq -r '.metadata.uid' <<<"$vjson")"
    if [ "$cur_uid" = "$victim_uid" ]; then
      delts="$(jq -r '.metadata.deletionTimestamp // ""' <<<"$vjson")"
      dreason="$(jq -r '(first(.status.conditions[]? | select(.type=="DisruptionTarget") | .reason)) // ""' <<<"$vjson")"
      { [ -n "$delts" ] || [ "$dreason" = "PreemptionByScheduler" ]; } \
        || fail "training pod $victim still intact (no deletionTimestamp, DisruptionTarget='$dreason') while inference runs — not a real eviction"
      echo "  victim $victim terminating (deletionTimestamp='${delts:-}', DisruptionTarget reason='${dreason:-}')"
    else
      echo "  victim $victim uid changed ($victim_uid -> $cur_uid) — original pod evicted"
    fi
  else
    echo "  victim $victim deleted — evicted by scheduler preemption"
  fi
  echo "  inference-critical preempted training-preemptible with a REAL eviction"
}

# s5: R12 containment — a pod with only the training tolerations cannot land
# on the warm-floor node; the scheduler must name the warm-floor taint.
scenario_s5_warm_floor_taint_blocks_training() {
  render_gpu_pod "$WORKLOADS/training-pod-warm-floor.yaml" warm-floor-probe 1 | k apply -f - >/dev/null
  echo "  submitted warm-floor-probe (training tolerations, nodeSelector pool=warm-floor)"
  psched_reason() {
    [ -n "$(k -n "$TEST_NS" get pod warm-floor-probe -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null)" ]
  }
  wait_for 60 "PodScheduled condition on warm-floor-probe" psched_reason
  local reason msg phase
  reason="$(k -n "$TEST_NS" get pod warm-floor-probe -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}')"
  msg="$(k -n "$TEST_NS" get pod warm-floor-probe -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}')"
  phase="$(k -n "$TEST_NS" get pod warm-floor-probe -o jsonpath='{.status.phase}')"
  [ "$reason" = "Unschedulable" ] || fail "warm-floor-probe PodScheduled reason='$reason' — expected Unschedulable"
  [ "$phase" = "Pending" ] || fail "warm-floor-probe phase='$phase' — expected Pending"
  case "$msg" in
    *pool.synorg.io/warm-floor*) ;;
    *) fail "warm-floor-probe unschedulable, but message does not name the warm-floor taint: $msg" ;;
  esac
  echo "  warm-floor-probe Pending/Unschedulable, scheduler names the taint: OK"
}

# s6: Karpenter provider-agnostic core on the kwok virtual substrate (KTD3).
# Virtual nodes never run pods and never advertise nvidia.com/gpu — this
# scenario only exercises NodePool provisioning, consolidation, and drift.
scenario_s6_karpenter_kwok_lifecycle() {
  if ! k get crd nodepools.karpenter.sh >/dev/null 2>&1 \
     || ! k get nodepool "$KWOK_NODEPOOL" >/dev/null 2>&1; then
    cat >&2 <<EOF
================================================================================
 SKIP (LOUD): kwok/Karpenter virtual-node substrate is ABSENT.
 The NodePool CRD or NodePool '$KWOK_NODEPOOL' is not in context '$KCTX' —
 the harness was probably brought up with 'tests/kind/up.sh --no-kwok'.
 Karpenter provisioning/consolidation/drift semantics are NOT being tested.
 Re-run tests/kind/up.sh without --no-kwok to cover them.
================================================================================
EOF
    exit 77
  fi

  kwok_sel="karpenter.sh/nodepool=$KWOK_NODEPOOL"
  kwok_nodeclaims() { k get nodeclaims -l "$kwok_sel" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true; }
  kwok_nodeclaim_exists() { [ -n "$(kwok_nodeclaims)" ]; }
  kwok_node_exists() { [ -n "$(k get nodes -l "$kwok_sel" -o name 2>/dev/null)" ]; }
  kwok_substrate_empty() { [ -z "$(kwok_nodeclaims)" ] && ! kwok_node_exists; }
  kwok_pod_bound() { [ -n "$(k -n "$TEST_NS" get pods -l app=kwok-probe -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)" ]; }

  # 6a — provisioning: a pending pod that tolerates the virtual taint makes the
  # NodePool provision a node carrying the template taints.
  k apply -f "$WORKLOADS/kwok-deployment.yaml" >/dev/null
  echo "  submitted kwok-probe deployment (tolerates karpenter.kwok.sh/virtual, pins nodepool=$KWOK_NODEPOOL)"
  wait_for "$WAIT_KWOK" "NodeClaim for NodePool $KWOK_NODEPOOL" kwok_nodeclaim_exists
  wait_for "$WAIT_KWOK" "kwok node registered" kwok_node_exists
  local node taint_val
  node="$(k get nodes -l "$kwok_sel" -o jsonpath='{.items[0].metadata.name}')"
  taint_val="$(k get node "$node" -o jsonpath='{.spec.taints[?(@.key=="karpenter.kwok.sh/virtual")].value}')"
  [ "$taint_val" = "true" ] || fail "provisioned kwok node $node lacks the template taint karpenter.kwok.sh/virtual=true (got '$taint_val')"
  wait_for "$WAIT_KWOK" "kwok-probe pod bound to a node" kwok_pod_bound
  local bound
  bound="$(k -n "$TEST_NS" get pods -l app=kwok-probe -o jsonpath='{.items[0].spec.nodeName}')"
  [ "$(k get node "$bound" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')" = "$KWOK_NODEPOOL" ] \
    || fail "kwok-probe bound to '$bound', which is not a $KWOK_NODEPOOL node"
  echo "  6a provision OK: node $node carries the virtual taint, pod bound to the pool"

  # 6b — consolidation: empty the node; WhenEmptyOrUnderutilized (10s) must
  # remove the now-lendable-and-empty virtual node.
  k -n "$TEST_NS" scale deployment kwok-probe --replicas=0 >/dev/null
  wait_for "$WAIT_KWOK" "empty kwok node consolidated away" kwok_substrate_empty
  echo "  6b consolidation OK: empty node and its NodeClaim removed"

  # 6c — drift: with demand present, a NodePool template change must REPLACE
  # the nodeclaim (old gone, new one provisioned). Template restored on exit.
  k -n "$TEST_NS" scale deployment kwok-probe --replicas=1 >/dev/null
  wait_for "$WAIT_KWOK" "NodeClaim reprovisioned for drift test" kwok_nodeclaim_exists
  local nc1
  nc1="$(k get nodeclaims -l "$kwok_sel" -o jsonpath='{.items[0].metadata.name}')"
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
  echo "  6c drift OK: $nc1 replaced by $(kwok_nodeclaims) after template change"
}

# s7: TAS / hot-swap — explicitly out of scope on kind (U3 packet #7).
scenario_s7_tas_hot_swap() {
  cat <<EOF
SKIP: TAS (Topology-Aware Scheduling) and hot-swap are OUT OF SCOPE on kind.
  - TAS needs real topology labels (nvidia.com/gpu.clique / cloud topology)
    that neither fake-gpu-operator nor kwok nodes advertise.
  - Hot-swap needs real node replacement on EKS capacity.
  These are covered by the cloud pilot ladder, not this harness.
EOF
  exit 77
}

# --- offline lint (--lint): no cluster required ------------------------------
# Red-first check for U3: written BEFORE the workloads existed, and it fails
# loudly on an empty workloads/ dir. Validates workload YAML schemas with
# kubeconform and asserts every queue/flavor/priority-class name referenced by
# the workloads (and hardcoded by this script) exists in clusters/pilot/kueue/.
run_lint() {
  need yq; need kubeconform
  local rc=0
  lint_err() { echo "LINT FAIL: $*" >&2; rc=1; }

  echo "lint: workloads dir: $WORKLOADS"
  shopt -s nullglob
  local files=("$WORKLOADS"/*.yaml)
  local kueue_files=("$KUEUE_DIR"/*.yaml)
  shopt -u nullglob
  [ "${#kueue_files[@]}" -gt 0 ] || fail "lint: no manifests in $KUEUE_DIR"
  if [ "${#files[@]}" -eq 0 ]; then
    fail "lint: no workload manifests in $WORKLOADS — the U3 workloads are missing"
  fi

  echo "lint: kubeconform -strict on ${#files[@]} workload file(s) (k8s $K8S_VERSION)"
  kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "${files[@]}" \
    || fail "lint: workload schema violations"

  # Source-of-truth names parsed (yq) out of clusters/pilot/kueue/.
  local lq_pairs cqs pcs rfs
  lq_pairs="$(yq -N 'select(.kind=="LocalQueue") | .metadata.name + "/" + .metadata.namespace' "${kueue_files[@]}")"
  cqs="$(yq -N 'select(.kind=="ClusterQueue") | .metadata.name' "${kueue_files[@]}")"
  pcs="$(yq -N 'select(.kind=="PriorityClass") | .metadata.name' "${kueue_files[@]}")"
  rfs="$(yq -N 'select(.kind=="ResourceFlavor") | .metadata.name' "${kueue_files[@]}")"

  # Internal consistency of the kueue manifests themselves.
  local ref
  while read -r ref; do
    [ -n "$ref" ] || continue
    grep -qxF "$ref" <<<"$cqs" || lint_err "LocalQueue points at ClusterQueue '$ref' — not defined in $KUEUE_DIR"
  done <<<"$(yq -N 'select(.kind=="LocalQueue") | .spec.clusterQueue' "${kueue_files[@]}")"
  while read -r ref; do
    [ -n "$ref" ] || continue
    grep -qxF "$ref" <<<"$rfs" || lint_err "ClusterQueue references flavor '$ref' — no such ResourceFlavor in $KUEUE_DIR"
  done <<<"$(yq -N 'select(.kind=="ClusterQueue") | .spec.resourceGroups[].flavors[].name' "${kueue_files[@]}")"

  # Names this script hardcodes must exist in the manifests.
  grep -qxF "$CQ" <<<"$cqs" || lint_err "test ClusterQueue '$CQ' not in $KUEUE_DIR"
  grep -qxF "$LQ/$TEAM_NS" <<<"$lq_pairs" || lint_err "test LocalQueue '$LQ' (ns '$TEAM_NS') not in $KUEUE_DIR"
  grep -qxF "$FLAVOR" <<<"$rfs" || lint_err "test flavor '$FLAVOR' not in $KUEUE_DIR"
  grep -qxF "$PC_INFERENCE" <<<"$pcs" || lint_err "PriorityClass '$PC_INFERENCE' not in $KUEUE_DIR"
  grep -qxF "$PC_TRAINING" <<<"$pcs" || lint_err "PriorityClass '$PC_TRAINING' not in $KUEUE_DIR"

  # Names each workload references must exist (queue-name label incl. its
  # namespace pairing, and every priorityClassName anywhere in the spec).
  local f q ns p
  for f in "${files[@]}"; do
    q="$(yq -N '.metadata.labels."kueue.x-k8s.io/queue-name" // ""' "$f")"
    if [ -n "$q" ]; then
      ns="$(yq -N '.metadata.namespace // ""' "$f")"
      grep -qxF "$q/$ns" <<<"$lq_pairs" \
        || lint_err "$(basename "$f"): queue-name '$q' has no LocalQueue in namespace '$ns' ($KUEUE_DIR)"
    fi
    while read -r p; do
      [ -n "$p" ] || continue
      grep -qxF "$p" <<<"$pcs" \
        || lint_err "$(basename "$f"): priorityClassName '$p' not defined in $KUEUE_DIR"
    done <<<"$(yq -N '.. | select(tag=="!!map") | select(has("priorityClassName")) | .priorityClassName' "$f")"
  done

  [ "$rc" -eq 0 ] || exit 1
  echo "LINT OK: ${#files[@]} workload manifest(s) schema-valid; queue/flavor/priority-class names consistent with $KUEUE_DIR"
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
  local pass=0 failn=0 skipn=0 failed="" s rc
  for s in "${SCENARIOS[@]}"; do
    echo
    echo "=== scenario: $s ==="
    rc=0
    # Each scenario runs as its own process: set -e stays honest inside the
    # scenario (no if-context errexit suppression) and its trap cleans its own
    # workloads before the next scenario starts.
    SCHEDULING_TEST_CHILD=1 bash "$SELF" "$s" || rc=$?
    case "$rc" in
      0)  pass=$((pass + 1)) ;;
      77) skipn=$((skipn + 1)); echo "SKIP: $s" ;;
      *)  failn=$((failn + 1)); failed="$failed $s"; echo "FAIL: $s (exit $rc)" ;;
    esac
  done
  echo
  echo "scheduling ladder: $pass passed, $skipn skipped, $failn failed${failed:+ —$failed}"
  [ "$failn" -eq 0 ]
}

case "${1:-}" in
  --list) printf '%s\n' "${SCENARIOS[@]}" ;;
  --lint) run_lint ;;
  -h|--help)
    sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'
    ;;
  "") run_all ;;
  *)  run_one "$1" ;;
esac
