#!/usr/bin/env bash
# attest_test.sh — R13/R14 attestation plumbing. No cluster needed (stub attestor
# + evidence-chain files), so it runs the same in the ladder and offline.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ATTEST="$ROOT/controllers/attest/attest-node.sh"
RECONCILE="$ROOT/controllers/lending/reconcile.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v jq >/dev/null 2>&1 || fail "jq"
command -v yq >/dev/null 2>&1 || fail "yq"

# R13 — the attest gate + stub attestor.
bash "$ATTEST" --lint || fail "attest-node --lint failed (gate + stub + record)"
pass "attest step: disabled=no-op, enabled+pass=verified+digest, enabled+fail=failed"

# R14 — tamper-evident evidence chain. Write records via the attest step (same
# hash-chain scheme as the reclaim path), verify intact, then tamper and drop.
SF="$(mktemp)"; EV="$(mktemp)"
printf 'attestation:\n  enabled: true\n  expectedImageDigest: "sha256:abc"\n' >"$SF"
: >"$EV"
for n in a b c; do ATTEST_SCHEDULE_FILE="$SF" EVIDENCE_FILE="$EV" STUB_ATTEST_RESULT=pass bash "$ATTEST" "node-$n" >/dev/null; done
[ "$(wc -l <"$EV" | tr -d ' ')" = 3 ] || fail "expected 3 chained records, got $(cat "$EV")"

EVIDENCE_FILE="$EV" bash "$RECONCILE" --verify-evidence "$EV" >/dev/null 2>&1 \
  || fail "R14: a freshly written chain must verify intact"
pass "R14: evidence chain verifies intact"

cp "$EV" "$EV.t"; sed -i.bak '2s/verified/failed/' "$EV.t"
EVIDENCE_FILE="$EV.t" bash "$RECONCILE" --verify-evidence "$EV.t" >/dev/null 2>&1 \
  && fail "R14: an altered record must break the chain"
pass "R14: altering a record breaks the chain (tamper-evident)"

cp "$EV" "$EV.d"; sed -i.bak '2d' "$EV.d"
EVIDENCE_FILE="$EV.d" bash "$RECONCILE" --verify-evidence "$EV.d" >/dev/null 2>&1 \
  && fail "R14: a dropped record must break the chain"
pass "R14: dropping a record breaks the chain"

echo "ATTEST OK"
