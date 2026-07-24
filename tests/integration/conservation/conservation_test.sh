#!/usr/bin/env bash
# conservation_test.sh — U5 integration ladder: the six-bucket conservation
# reconciliation (R18/R19) on the kind harness (tests/kind/up.sh).
#
# The "never descale" invariant is proven, not assumed: every held node must
# occupy exactly one of five states, and their sum must equal held. A node in
# NONE of them (an operator-parked cordon that is not lent) makes the sum fall
# short — a non-zero residual, which R19 treats as a capacity incident.
#
# This is the authoritative partition + sum assertion. The Prometheus mirror is
# clusters/pilot/observability/recording-rules.yaml (group `conservation`); the
# held-vs-ODCR tie-out is the lending ledger (tests/e2e/assertions.sh,
# credential-gated, OUTSIDE this unit's DoD — reservation state needs terraform
# and AWS). Keep the bucket definitions here in sync with the recording rules.
#
# Usage:
#   conservation_test.sh          full run (Makefile `integration` entry): creates
#                                 synthetic Node objects, classifies, asserts
#   conservation_test.sh --lint   offline: run the classifier against a synthetic
#                                 node-JSON fixture, no cluster
#
# Style follows scheduling_test.sh: need/fail/k helpers, set -euo pipefail,
# trap cleanup that deletes only the test-labeled nodes.
#
# shellcheck disable=SC2317
set -euo pipefail

KCTX="${CONSERVATION_TEST_CONTEXT:-kind-synorg}"
TEST_LABEL="synorg.io/conservation-test"
LENT="lending.synorg.io/lent"
QUAR="lending.synorg.io/quarantine"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so local runs match CI"; }
k()    { kubectl --context "$KCTX" "$@"; }

# classify_and_tally — read a Kubernetes NodeList JSON on stdin (already scoped
# to the held book) and print one "bucket count" line per bucket plus held and
# residual. Precedence (disjoint by construction, mirrors the recording rules):
#   quarantine > in_transit(lent+cordoned) > lent(lent+schedulable) >
#   owner_idle_floor(warm-floor) > owner_serving(lendable, schedulable) > stray
# Nodes are scoped by the caller; every held node lands in exactly one bucket or
# in `stray`, and residual = held - Σ(five buckets) = count(stray).
CLASSIFY='
  def pool: .metadata.labels["karpenter.sh/nodepool"] // "";
  def haskey($k): (.spec.taints // []) | any(.key == $k);
  def cordoned: (.spec.unschedulable // false) == true;
  def bucket:
    if haskey("'"$QUAR"'") then "quarantine"
    elif haskey("'"$LENT"'") and cordoned then "in_transit"
    elif haskey("'"$LENT"'") then "lent"
    elif pool == "gpu-warm-floor" then "owner_idle_floor"
    elif pool == "gpu-lendable" and (cordoned | not) then "owner_serving"
    else "stray" end;
  [ .items[] | bucket ] as $b
  | { held: ($b | length),
      owner_serving:    ([$b[] | select(. == "owner_serving")]    | length),
      owner_idle_floor: ([$b[] | select(. == "owner_idle_floor")] | length),
      lent:             ([$b[] | select(. == "lent")]             | length),
      in_transit:       ([$b[] | select(. == "in_transit")]       | length),
      quarantine:       ([$b[] | select(. == "quarantine")]       | length),
      stray:            ([$b[] | select(. == "stray")]            | length) }
  | .residual = (.held - (.owner_serving + .owner_idle_floor + .lent + .in_transit + .quarantine))
'

assert_reconciles() { # JSON expected_held expected_residual
  local out held residual
  out="$(jq "$CLASSIFY" <<<"$1")"
  held="$(jq -r .held <<<"$out")"; residual="$(jq -r .residual <<<"$out")"
  [ "$held" = "$2" ] || fail "held=$held, expected $2 — $out"
  [ "$residual" = "$3" ] || fail "residual=$residual, expected $3 — $out"
  # residual must equal the stray count by construction (the reconciliation identity)
  [ "$residual" = "$(jq -r .stray <<<"$out")" ] || fail "residual != stray count — $out"
}

# --- offline lint: classifier against a synthetic fixture, no cluster ---------
if [ "${1:-}" = "--lint" ]; then
  need jq
  # Six well-formed states, one each, all held → held=6, residual=0.
  WELL='{"items":[
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{}},
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-warm-floor"}},"spec":{}},
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{"taints":[{"key":"'"$LENT"'","effect":"NoSchedule"}]}},
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{"unschedulable":true,"taints":[{"key":"'"$LENT"'","effect":"NoSchedule"}]}},
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{"taints":[{"key":"'"$QUAR"'","effect":"NoSchedule"}]}}
  ]}'
  assert_reconciles "$WELL" 5 0
  pass "offline: five well-formed states reconcile (held=5, residual=0)"
  # Add a stray: lendable, cordoned, NOT lent, NOT quarantine → in no bucket.
  STRAY='{"items":[
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{}},
    {"metadata":{"labels":{"karpenter.sh/nodepool":"gpu-lendable"}},"spec":{"unschedulable":true}}
  ]}'
  assert_reconciles "$STRAY" 2 1
  pass "offline: an operator-parked stray raises residual=1 (R19 incident)"
  echo "CONSERVATION LINT OK"
  exit 0
fi

# --- full run: synthetic Node objects on a real apiserver --------------------
need kubectl; need jq
k version --request-timeout=10s >/dev/null 2>&1 || fail "no reachable cluster at context $KCTX"

NODES=(cons-serving cons-floor cons-lent cons-transit cons-quar cons-stray)
cleanup() { for n in "${NODES[@]}"; do k delete node "$n" --ignore-not-found >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

mknode() { # name nodepool  [extra jq spec merge]
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Node
metadata: {name: $1, labels: {karpenter.sh/nodepool: $2, $TEST_LABEL: "true"}}
spec: {}
EOF
}
mknode cons-serving gpu-lendable
mknode cons-floor   gpu-warm-floor
mknode cons-lent    gpu-lendable
mknode cons-transit gpu-lendable
mknode cons-quar    gpu-lendable
mknode cons-stray   gpu-lendable
k taint node cons-lent    "$LENT=true:NoSchedule" >/dev/null
k taint node cons-transit "$LENT=true:NoSchedule" >/dev/null
k cordon cons-transit >/dev/null
k taint node cons-quar    "$QUAR=true:NoSchedule" >/dev/null
k cordon cons-stray >/dev/null   # parked, not lent, not quarantine → stray

# Scope to the test-labeled nodes; well-formed set excludes the stray in jq.
ALL="$(k get nodes -l "$TEST_LABEL=true" -o json)"
WF="$(jq '.items |= map(select(.metadata.name != "cons-stray"))' <<<"$ALL")"
assert_reconciles "$WF" 5 0
pass "five well-formed held nodes reconcile (held=5, residual=0)"
# Full set including the stray: held=6, residual=1 → incident detectable.
assert_reconciles "$ALL" 6 1
pass "the parked stray node surfaces as residual=1 (R19 capacity incident)"
echo "CONSERVATION OK"
