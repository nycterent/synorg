#!/usr/bin/env bash
# upgrade-drain.sh (R11) — cluster-upgrade node-drain orchestrator, the SECOND
# consumer of the shared drain budget (U7). Reclaim draws first; an upgrade gets
# only the headroom the reclaim waves leave. Drains nodes for a component or
# node-image upgrade ONE AT A TIME, each gated by three conditions:
#   1. drain budget available  — consulted via `reconcile.sh --budget-acquire
#      upgrade` (AE2: a reclaim in flight makes the upgrade wait)
#   2. owner floor intact      — a minimum of never-lent warm-floor Ready nodes
#      must remain, so an upgrade never erodes the latency insurance floor
#   3. RTS p95 under budget     — if return-to-service is already stressed, an
#      upgrade's extra drains would compound it; halt instead
# Any stop condition HALTS the run loudly (non-zero exit) rather than pressing on.
#
# What this does NOT own: the actual reimage. Like reclaim, the drain hands the
# node to the platform's node lifecycle (Karpenter drift / the node's own
# upgrade path); this orchestrator owns only the SAFE, BUDGETED sequencing of
# the drains. Cluster upgrades were previously undriven (KTD6); this is the unit
# that makes the drain budget's second consumer real and closes AE2.
#
# Usage:
#   upgrade-drain.sh --nodes "n1 n2"   drain the named nodes for upgrade, budgeted
#   upgrade-drain.sh --selector L=V     drain nodes matching a label selector
#   upgrade-drain.sh --plan ...         dry-run: report candidates + gate state, no drain
#   upgrade-drain.sh --lint             offline: stop-condition + budget arithmetic, no cluster
#
# Env:
#   UPGRADE_RECONCILE           path to reconcile.sh (default: sibling ../lending/reconcile.sh)
#   UPGRADE_SCHEDULE_FILE       lending schedule ConfigMap-body path (owner-floor + RTS budget config)
#   UPGRADE_RTS_P95_SECONDS     inject the current RTS p95 (test hook; prod reads the SLO API)
#   UPGRADE_CONTEXT             kube context
#   KUBECTL_CACHE_DIR           kubectl cache dir
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE="${UPGRADE_RECONCILE:-$HERE/../lending/reconcile.sh}"
# Exported so the reconcile.sh --budget-acquire child reads the same schedule.
export SCHEDULE_FILE="${UPGRADE_SCHEDULE_FILE:-/etc/lending/schedule.yaml}"
KUBECTL_CACHE_DIR="${KUBECTL_CACHE_DIR:-/tmp/kubectl-cache-upgrade}"
KCTX="${UPGRADE_CONTEXT:-}"
WARM_FLOOR_POOL="gpu-warm-floor"

log() { echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) level=$1 component=upgrade-drain ${*:2}"; }
kc()  { if [ -n "$KCTX" ]; then kubectl --context "$KCTX" --cache-dir="$KUBECTL_CACHE_DIR" --request-timeout=30s "$@"
        else kubectl --cache-dir="$KUBECTL_CACHE_DIR" --request-timeout=30s "$@"; fi; }

# owner_floor_ok — the never-lent warm-floor pool must keep at least
# upgrade.ownerFloorMinNodes Ready nodes. An upgrade drain must never take the
# floor below that; the floor is the latency insurance an upgrade cannot spend.
owner_floor_ok() {
  local minf ready
  minf="$(yq -r '.upgrade.ownerFloorMinNodes // 1' "$SCHEDULE_FILE")"
  ready="$(kc get nodes -l "karpenter.sh/nodepool=$WARM_FLOOR_POOL" -o json \
    | jq '[.items[] | select(.spec.unschedulable != true)
           | select(.status.conditions // [] | any(.type == "Ready" and .status == "True"))] | length')"
  [ "$ready" -ge "$minf" ]
}

# rts_p95_ok — halt upgrades when return-to-service is already stressed. The RTS
# p95 comes from the injected test value or (in prod) the SLO API; the budget is
# the pinned nodeReturnToServiceBudgetSeconds. If no RTS source is available, the
# owner-floor and drain-budget gates still apply — proceed with a warning rather
# than block upgrades forever on a missing metrics endpoint.
rts_p95_ok() {
  local budget rts
  budget="$(yq -r '.upgrade.rtsP95BudgetSeconds // .nodeReturnToServiceBudgetSeconds // 0' "$SCHEDULE_FILE")"
  rts="${UPGRADE_RTS_P95_SECONDS:-}"
  if [ -z "$rts" ]; then
    log warn msg="no RTS p95 source (set UPGRADE_RTS_P95_SECONDS or wire the SLO API) — proceeding on owner-floor + budget gates only"
    return 0
  fi
  [ "$budget" -eq 0 ] 2>/dev/null && return 0    # 0 = unbudgeted
  # integer-seconds comparison; RTS over budget halts.
  [ "${rts%.*}" -le "$budget" ]
}

# budget_ok — reclaim draws first; the upgrade consults the SAME budget via the
# lending controller's consult interface (SCHEDULE_FILE is exported above).
budget_ok() { bash "$RECONCILE" --budget-acquire upgrade >/dev/null 2>&1; }

# stop_conditions_ok — the two HALT gates (owner floor, RTS). Budget is a DEFER
# gate (wait, don't halt), handled separately in the drain loop.
stop_conditions_ok() {
  if ! owner_floor_ok; then log error action=upgrade_halt reason=owner_floor msg="warm-floor Ready nodes below the minimum — refusing to drain for upgrade"; return 1; fi
  if ! rts_p95_ok;    then log error action=upgrade_halt reason=rts_p95    msg="RTS p95 over budget — refusing to add upgrade drains to a stressed return path"; return 1; fi
  return 0
}

drain_one() {  # node
  local node="$1"
  log info action=upgrade_drain_start node="$node"
  kc cordon "$node" >/dev/null
  kc drain "$node" --ignore-daemonsets --delete-emptydir-data --grace-period=120 --timeout=360s >/dev/null \
    || log warn action=drain_incomplete node="$node" msg="drain did not finish cleanly"
  log info action=upgrade_drain_done node="$node"
}

# --- offline lint: stop-condition + budget arithmetic, no cluster ------------
if [ "${1:-}" = "--lint" ]; then
  command -v yq >/dev/null 2>&1 || { echo "LINT FAIL: yq not installed" >&2; exit 1; }
  bash -n "$0" || { echo "LINT FAIL: syntax" >&2; exit 1; }
  SF="$(mktemp)"; printf 'upgrade:\n  ownerFloorMinNodes: 1\n  rtsP95BudgetSeconds: 600\n' >"$SF"
  SCHEDULE_FILE="$SF"
  UPGRADE_RTS_P95_SECONDS=500 rts_p95_ok || { echo "LINT FAIL: rts 500 <= 600 should pass" >&2; exit 1; }
  UPGRADE_RTS_P95_SECONDS=700 rts_p95_ok && { echo "LINT FAIL: rts 700 > 600 must halt" >&2; exit 1; }
  UPGRADE_RTS_P95_SECONDS="" rts_p95_ok || { echo "LINT FAIL: missing RTS source should proceed (warn)" >&2; exit 1; }
  echo "UPGRADE-DRAIN LINT OK"
  exit 0
fi

# --- main --------------------------------------------------------------------
PLAN=0; NODES=""; SELECTOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1 ;;
    --nodes) NODES="$2"; shift ;;
    --selector) SELECTOR="$2"; shift ;;
    *) log error msg="unknown arg '$1'"; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { log error msg="jq not installed"; exit 1; }
mkdir -p "$KUBECTL_CACHE_DIR"

candidates() {
  if [ -n "$NODES" ]; then printf '%s\n' $NODES
  elif [ -n "$SELECTOR" ]; then kc get nodes -l "$SELECTOR" -o name | cut -d/ -f2
  else log error msg="no --nodes or --selector given"; exit 2; fi
}

# Stop conditions are HALT gates: check once up front and before each drain.
stop_conditions_ok || exit 1

deferred=0; drained=0
while IFS= read -r node; do
  [ -n "$node" ] || continue
  stop_conditions_ok || { log error action=upgrade_halt node="$node" msg="stop condition tripped mid-run — halting with $drained drained, $deferred deferred"; exit 1; }
  if ! budget_ok; then
    log info action=upgrade_deferred node="$node" reason=drain_budget_full msg="reclaim holds the drain budget — upgrade waits (retry next run)"
    deferred=$((deferred + 1)); continue
  fi
  if [ "$PLAN" = "1" ]; then log info action=upgrade_plan node="$node" msg="would drain (budget granted, stop conditions clear)"; drained=$((drained + 1)); continue; fi
  drain_one "$node"; drained=$((drained + 1))
done < <(candidates)

log info action=upgrade_summary drained="$drained" deferred="$deferred"
[ "$deferred" -eq 0 ] || log warn msg="$deferred node(s) deferred on drain budget — re-run once reclaim frees headroom"
