#!/usr/bin/env bash
# upgrade_test.sh — R11 integration ladder: the upgrade-drain orchestrator
# (controllers/upgrade/upgrade-drain.sh) as the drain budget's SECOND consumer.
#
# Closes AE2: a reclaim in flight holds the drain budget, so an eligible upgrade
# WAITS; when the reclaim frees the budget the upgrade proceeds. Plus the
# owner-floor stop condition halts an upgrade that would take the warm floor
# below its minimum.
#
# Usage:
#   upgrade_test.sh          full run (Makefile `integration` entry): synthetic
#                            nodes on a real apiserver, budget + stop-condition gates
#   upgrade_test.sh --lint   offline: delegate to upgrade-drain --lint (stop-condition
#                            arithmetic), no cluster
#
# Style follows conservation_test.sh: need/fail/k helpers, set -euo pipefail,
# trap cleanup deleting only the test-labeled nodes. Tools under test use the
# AMBIENT kube context (kind-synorg in the ladder), same as the lending suite.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DRAIN="$ROOT/controllers/upgrade/upgrade-drain.sh"
KCTX="${UPGRADE_TEST_CONTEXT:-kind-synorg}"
LENT="lending.synorg.io/lent"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1)"; }
k()    { kubectl --context "$KCTX" "$@"; }

# --- offline lint ------------------------------------------------------------
if [ "${1:-}" = "--lint" ]; then
  need yq
  bash "$DRAIN" --lint || fail "upgrade-drain --lint failed"
  echo "UPGRADE LINT OK"
  exit 0
fi

# --- full run ----------------------------------------------------------------
need kubectl; need jq; need yq
k version --request-timeout=10s >/dev/null 2>&1 || fail "no reachable cluster at context $KCTX"

TMP="$(mktemp -d)"
# Test schedule: cap=1 so a single in-flight reclaim exhausts the budget.
SCHED="$TMP/schedule.yaml"
cat >"$SCHED" <<EOF
targets:
  lendablePool: gpu-lendable
  maxConcurrentDrains: 1
upgrade:
  ownerFloorMinNodes: 1
  rtsP95BudgetSeconds: 600
EOF

NODES=(up-inflight up-floor up-target)
cleanup() { for n in "${NODES[@]}"; do k delete node "$n" --ignore-not-found >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

mknode() { k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Node
metadata: {name: $1, labels: {karpenter.sh/nodepool: $2}}
spec: {}
status: {conditions: [{type: Ready, status: "True"}]}
EOF
}
mknode up-inflight gpu-lendable
mknode up-floor    gpu-warm-floor
mknode up-target   gpu-lendable
# up-inflight = a reclaim in flight: lent + cordoned + reclaiming marker. This is
# what the drain budget counts, so with cap=1 it fills the budget.
k taint node up-inflight "$LENT=true:NoSchedule" >/dev/null
k annotate node up-inflight lending.synorg.io/reclaiming="$(date -u +%FT%TZ)" >/dev/null
k cordon up-inflight >/dev/null

run_drain() { UPGRADE_SCHEDULE_FILE="$SCHED" UPGRADE_RTS_P95_SECONDS=100 bash "$DRAIN" --plan --nodes up-target 2>&1; }

# AE2 part 1 — reclaim holds the budget, the upgrade WAITS.
OUT="$(run_drain)"
echo "$OUT" | grep -q 'action=upgrade_deferred node=up-target' \
  || fail "AE2: upgrade was not deferred while a reclaim holds the drain budget: $OUT"
echo "$OUT" | grep -q 'action=upgrade_plan' \
  && fail "AE2: upgrade drained while the budget was full — must wait: $OUT"
pass "AE2: reclaim holds the drain budget, upgrade defers (waits)"

# AE2 part 2 — free the reclaim, the upgrade PROCEEDS.
k annotate node up-inflight lending.synorg.io/reclaiming- >/dev/null
k uncordon up-inflight >/dev/null
k taint node up-inflight "$LENT:NoSchedule-" >/dev/null
OUT="$(run_drain)"
echo "$OUT" | grep -q 'action=upgrade_plan node=up-target' \
  || fail "AE2: upgrade did not proceed after the reclaim freed the budget: $OUT"
pass "AE2: budget freed → upgrade proceeds"

# Owner-floor stop condition — raise the floor minimum above what exists → HALT.
cat >"$SCHED" <<EOF
targets: {lendablePool: gpu-lendable, maxConcurrentDrains: 1}
upgrade: {ownerFloorMinNodes: 5, rtsP95BudgetSeconds: 600}
EOF
set +e
OUT="$(UPGRADE_SCHEDULE_FILE="$SCHED" UPGRADE_RTS_P95_SECONDS=100 bash "$DRAIN" --plan --nodes up-target 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "owner-floor: run should halt (non-zero) when the floor is below minimum: $OUT"
echo "$OUT" | grep -q 'action=upgrade_halt reason=owner_floor' \
  || fail "owner-floor: no owner_floor halt logged: $OUT"
pass "owner-floor stop condition halts the upgrade before eroding the floor"

echo "UPGRADE OK"
