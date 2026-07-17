#!/usr/bin/env bash
# test.sh — U4 lending-controller (v0) test scenarios.
#
# Two tiers:
#   offline (always runs, no cluster needed):
#     1. bash -n syntax check on reconcile.sh
#     2. RBAC-verb-subset check: every kubectl invocation in reconcile.sh maps
#        to (apiGroup, resource, verb) tuples, and that set must be a subset of
#        what clusters/pilot/lending/lending-controller.yaml grants. This is
#        the "controller uses only granted RBAC verbs" scenario, runnable
#        without a cluster.
#     3. malformed-schedule scenario: a garbage schedule yields a clear
#        schedule_invalid log and a clean exit, not a crash (validation runs
#        before any kubectl call, so no cluster is needed).
#   live (runs when a kubecontext answers; the U1 kind harness drives this):
#     4. window open  -> lent taint added to the lendable node
#        window closed -> lent taint removed
#     5. shrunk curve value -> ClusterQueue borrowingLimit patched to match
#     6. reclaim tick on a cluster without Karpenter (kind) -> intended
#        nodeclaim delete is LOGGED, exit stays clean
#
# Usage: test.sh [--offline]   (--offline skips the live tier explicitly;
#        the live tier also auto-skips when no cluster is reachable)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RECONCILE="$HERE/reconcile.sh"
RBAC_FILE="$ROOT/clusters/pilot/lending/lending-controller.yaml"

fail() { echo "TEST FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1)"; }

need yq
need jq

OFFLINE_ONLY=0
[ "${1:-}" = "--offline" ] && OFFLINE_ONLY=1

# --- 1. syntax -------------------------------------------------------------

[ -f "$RECONCILE" ] || fail "reconcile.sh not found at $RECONCILE — the controller loop does not exist yet"
bash -n "$RECONCILE" || fail "reconcile.sh has syntax errors"
pass "bash -n reconcile.sh"

# --- 2. RBAC-verb-subset check (offline) -----------------------------------
# Contract with reconcile.sh (stated there too): every kubectl call goes
# through the single-line `kc <subcommand> <resource> ...` wrapper, with the
# resource token immediately after the subcommand. That keeps this parser
# honest: it reads the ACTUAL invocations, not a hand-maintained list, and it
# fails closed on anything it cannot map.

# granted_rules — "group|resource|verb" lines granted by the ClusterRole+Role.
granted_rules() {
  # shellcheck disable=SC2016  # $g/$r/$v are yq variables, not shell
  yq eval-all '
    select(.kind == "ClusterRole" or .kind == "Role")
    | .rules[]
    | (.apiGroups[]) as $g
    | (.resources[]) as $r
    | (.verbs[]) as $v
    | $g + "|" + $r + "|" + $v
  ' "$RBAC_FILE" | grep -v '^---$'
}

# invocations — the argv tail of every `kc ...` call in reconcile.sh, one per
# line, comments excluded, cut at the first shell metacharacter.
invocations() {
  grep -vE '^[[:space:]]*#' "$RECONCILE" \
    | grep -oE '(^|[^A-Za-z0-9_$])kc[[:space:]]+[^|>#;)&]*' \
    | sed -E 's/.*kc[[:space:]]+//' \
    | sed -E 's/[[:space:]]+$//' \
    | grep -v '^$'
}

# normalize_resource TOKEN — kubectl resource token -> canonical plural name.
normalize_resource() {
  case "$1" in
    node|nodes) echo nodes ;;
    clusterqueue|clusterqueues|clusterqueues.kueue.x-k8s.io) echo clusterqueues ;;
    nodeclaim|nodeclaims|nodeclaims.karpenter.sh) echo nodeclaims ;;
    pod|pods) echo pods ;;
    *) echo "$1" ;;
  esac
}

# required_rules — map each invocation to the "group|resource|verb" tuples it
# needs. Unknown subcommands or unparseable resources FAIL the check: the
# safety property is that nothing escapes the mapping.
required_rules() {
  local line sub res
  while IFS= read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    sub="$1"
    case "$sub" in
      api-versions|version)
        # API discovery — granted to all authenticated users, not RBAC-scoped.
        ;;
      get)
        res="$(normalize_resource "${2:-}")"
        case "$res" in
          nodes)         printf '%s\n' "|nodes|get" "|nodes|list" ;;
          clusterqueues) printf '%s\n' "kueue.x-k8s.io|clusterqueues|get" "kueue.x-k8s.io|clusterqueues|list" ;;
          nodeclaims)    printf '%s\n' "karpenter.sh|nodeclaims|get" "karpenter.sh|nodeclaims|list" ;;
          pods)          printf '%s\n' "|pods|get" "|pods|list" ;;
          *) fail "RBAC check: unmapped 'kc get $res' in reconcile.sh" ;;
        esac ;;
      taint)
        # kubectl taint reads then updates/patches the Node object.
        printf '%s\n' "|nodes|get" "|nodes|patch" "|nodes|update" ;;
      cordon)
        printf '%s\n' "|nodes|get" "|nodes|patch" ;;
      drain)
        # drain = cordon (nodes patch) + list pods + eviction API.
        printf '%s\n' "|nodes|get" "|nodes|patch" "|pods|get" "|pods|list" "|pods/eviction|create" ;;
      patch)
        res="$(normalize_resource "${2:-}")"
        case "$res" in
          clusterqueues) printf '%s\n' "kueue.x-k8s.io|clusterqueues|patch" ;;
          nodes)         printf '%s\n' "|nodes|patch" ;;
          *) fail "RBAC check: unmapped 'kc patch $res' in reconcile.sh" ;;
        esac ;;
      delete)
        res="$(normalize_resource "${2:-}")"
        case "$res" in
          nodeclaims) printf '%s\n' "karpenter.sh|nodeclaims|delete" ;;
          *) fail "RBAC check: unmapped 'kc delete $res' in reconcile.sh" ;;
        esac ;;
      create)
        # The only create in reconcile.sh is `kc create -f -` fed an Event
        # manifest; assert that is really true, then map to events create.
        [ "${2:-}" = "-f" ] || fail "RBAC check: 'kc create' without -f in reconcile.sh"
        grep -q 'kind: Event' "$RECONCILE" || fail "RBAC check: 'kc create -f' present but no 'kind: Event' manifest found"
        printf '%s\n' "|events|create" ;;
      *)
        fail "RBAC check: unmapped kubectl subcommand 'kc $sub' in reconcile.sh" ;;
    esac
  done < <(invocations)
}

# Raw kubectl outside the kc() wrapper defeats the parser — forbid it.
if grep -vE '^[[:space:]]*#' "$RECONCILE" | grep -v '^kc()' | grep -qE '(^|[^A-Za-z0-9_./-])kubectl([[:space:]]|$)'; then
  fail "reconcile.sh calls kubectl outside the kc() wrapper — RBAC check cannot see it"
fi

GRANTED="$(granted_rules | sort -u)"
REQUIRED="$(required_rules | sort -u)"
[ -n "$REQUIRED" ] || fail "RBAC check: no kubectl invocations found in reconcile.sh (parser broken?)"

MISSING=""
while IFS= read -r rule; do
  echo "$GRANTED" | grep -qxF "$rule" || MISSING="$MISSING $rule"
done <<<"$REQUIRED"
[ -z "$MISSING" ] || fail "RBAC check: reconcile.sh needs verbs the Role does not grant:$MISSING"
pass "RBAC subset: $(echo "$REQUIRED" | wc -l | tr -d ' ') required tuples all granted"

# --- 3. malformed schedule -> clear log, no crash (offline) ----------------

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

printf 'this is: [not: valid yaml\n' >"$TMPDIR_T/bad-schedule.yaml"
set +e
BAD_OUT="$(SCHEDULE_FILE="$TMPDIR_T/bad-schedule.yaml" MAX_TICKS=2 TICK_SECONDS=0 bash "$RECONCILE" 2>&1)"
BAD_RC=$?
set -e
[ "$BAD_RC" -eq 0 ] || fail "malformed schedule crashed the loop (rc=$BAD_RC): $BAD_OUT"
echo "$BAD_OUT" | grep -q 'schedule_invalid' || fail "malformed schedule did not log schedule_invalid: $BAD_OUT"
[ "$(echo "$BAD_OUT" | grep -c 'schedule_invalid')" -ge 2 ] || fail "loop did not survive to a second tick on malformed schedule"
pass "malformed schedule: schedule_invalid logged, ticks skipped, no crash-loop"

# --- live tier -------------------------------------------------------------

if [ "$OFFLINE_ONLY" = "1" ]; then
  skip "live tier (--offline)"
  echo "ALL OFFLINE CHECKS PASSED"
  exit 0
fi
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  skip "live tier (no reachable cluster)"
  echo "ALL OFFLINE CHECKS PASSED"
  exit 0
fi

POOL_LABEL="karpenter.sh/nodepool=gpu-lendable"
TAINT_KEY="lending.synorg.io/lent"
NODE="${TEST_NODE:-$(kubectl get nodes -o name | head -1 | cut -d/ -f2)}"
[ -n "$NODE" ] || fail "live tier: no node found"

cleanup_live() {
  kubectl label node "$NODE" karpenter.sh/nodepool- >/dev/null 2>&1 || true
  kubectl taint node "$NODE" "$TAINT_KEY:NoSchedule-" >/dev/null 2>&1 || true
}
trap 'cleanup_live; rm -rf "$TMPDIR_T"' EXIT
kubectl label node "$NODE" "$POOL_LABEL" --overwrite >/dev/null

# fixture SCHEDULE_PATH OPENS CLOSES DAYS_YAML PCT WAVES_YAML
write_fixture() {
  cat >"$1" <<EOF
schemaVersion: 1
timezone: UTC
productionRampAt: "07:00"
targets:
  lendablePool: gpu-lendable
  lentTaint: "lending.synorg.io/lent=true:NoSchedule"
  trainingQueue: training-borrow
windows:
  - name: test-window
    opensAt: "$2"
    closesAt: "$3"
    days: $4
borrowingLimitCurve:
  - at: "00:00"
    gpuLimitPct: $5
reclaimWaves: $6
nodeReturnToServiceBudgetSeconds: 600
nightScrubRotation: false
EOF
}

ALL_DAYS='["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]'

# 4a. window open -> lent taint added
write_fixture "$TMPDIR_T/open.yaml" "00:00" "23:59" "$ALL_DAYS" 100 "[]"
SCHEDULE_FILE="$TMPDIR_T/open.yaml" MAX_TICKS=1 TICK_SECONDS=0 bash "$RECONCILE"
kubectl get node "$NODE" -o json | jq -e --arg k "$TAINT_KEY" '.spec.taints // [] | any(.key == $k)' >/dev/null \
  || fail "window open: lent taint not added to $NODE"
pass "window open: lent taint added"

# 4b. window closed -> lent taint removed
write_fixture "$TMPDIR_T/closed.yaml" "00:00" "23:59" "[]" 100 "[]"
SCHEDULE_FILE="$TMPDIR_T/closed.yaml" MAX_TICKS=1 TICK_SECONDS=0 bash "$RECONCILE"
kubectl get node "$NODE" -o json | jq -e --arg k "$TAINT_KEY" '.spec.taints // [] | any(.key == $k) | not' >/dev/null \
  || fail "window closed: lent taint not removed from $NODE"
pass "window closed: lent taint removed"

# 5. shrunk curve -> borrowingLimit patched to match (needs Kueue + the queue)
if kubectl get clusterqueue training-borrow >/dev/null 2>&1; then
  ORIG_LIMIT="$(kubectl get clusterqueue training-borrow -o json \
    | jq -r '[.spec.resourceGroups[].flavors[].resources[] | select(.name == "nvidia.com/gpu")][0].borrowingLimit')"
  write_fixture "$TMPDIR_T/shrunk.yaml" "00:00" "23:59" "$ALL_DAYS" 0 "[]"
  SCHEDULE_FILE="$TMPDIR_T/shrunk.yaml" MAX_TICKS=1 TICK_SECONDS=0 bash "$RECONCILE"
  GOT="$(kubectl get clusterqueue training-borrow -o json \
    | jq -r '[.spec.resourceGroups[].flavors[].resources[] | select(.name == "nvidia.com/gpu")][0].borrowingLimit')"
  [ "$GOT" = "0" ] || fail "shrunk curve: borrowingLimit is $GOT, expected 0"
  pass "shrunk curve: borrowingLimit patched to 0"
  kubectl patch clusterqueue training-borrow --type=json \
    -p "[{\"op\": \"replace\", \"path\": \"$(kubectl get clusterqueue training-borrow -o json \
      | jq -r 'first(.spec.resourceGroups | to_entries[] as $g | $g.value.flavors | to_entries[] as $f | $f.value.resources | to_entries[] as $r | select($r.value.name == "nvidia.com/gpu") | "/spec/resourceGroups/\($g.key)/flavors/\($f.key)/resources/\($r.key)/borrowingLimit")')\", \"value\": $ORIG_LIMIT}]" >/dev/null
else
  skip "shrunk curve scenario (no training-borrow ClusterQueue on this cluster)"
fi

# 6. reclaim tick on kind -> intended nodeclaim delete logged, no error
NOW_HM="$(TZ=UTC date +%H:%M)"
write_fixture "$TMPDIR_T/reclaim.yaml" "00:00" "23:59" "$ALL_DAYS" 100 \
  "[{name: test-wave, startsAt: \"$NOW_HM\", reclaimFraction: 1.0, drainGraceSeconds: 120, preferPreScrubbed: true}]"
# ensure the node is lent so the wave has something to reclaim
SCHEDULE_FILE="$TMPDIR_T/open.yaml" MAX_TICKS=1 TICK_SECONDS=0 bash "$RECONCILE" >/dev/null
if kubectl api-versions | grep -q '^karpenter.sh/'; then
  skip "kind reclaim scenario (Karpenter present — this is not the kind path)"
else
  set +e
  RECLAIM_OUT="$(SCHEDULE_FILE="$TMPDIR_T/reclaim.yaml" MAX_TICKS=1 TICK_SECONDS=0 bash "$RECONCILE" 2>&1)"
  RECLAIM_RC=$?
  set -e
  [ "$RECLAIM_RC" -eq 0 ] || fail "reclaim tick errored on kind (rc=$RECLAIM_RC): $RECLAIM_OUT"
  echo "$RECLAIM_OUT" | grep -q 'reclaim_intent' || fail "reclaim tick did not log intended nodeclaim delete: $RECLAIM_OUT"
  pass "kind reclaim: intended nodeclaim delete logged, no error"
fi

echo "ALL CHECKS PASSED"
