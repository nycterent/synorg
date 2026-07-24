#!/usr/bin/env bash
# attest-node.sh (R13) — attest a node that has rejoined the owner pool after a
# scrub-and-reimage, BEFORE it may serve owner workload. Verifies the node booted
# the expected golden image; records the result in the tamper-evident evidence
# chain and emits the attest-stage duration that populates the RTS attest series
# (rts_attest_seconds:p95, declared-absent in U3 until this exists).
#
# PASS-1 DEFAULT: attestation.enabled = false → this is a no-op and the reclaim
# path's records stay attestation=not-enforced (KTD4). Flipping enabled to true
# is the pass-2 step that closes the no-attestation window (pass2Gate deadline).
#
# STUB ATTESTOR: the actual measurement is TPM-backed image-hash proof on real
# hardware (money — needs the pilot). The CONTROL FLOW is complete and testable
# now with a stub: STUB_ATTEST_RESULT=pass|fail (test hook) or ATTEST_CMD=<cmd>
# (prod: a command that exits 0 on a verified match). Only the attestor is stubbed;
# the gate, the evidence record, the duration metric, and the chain are real.
#
# Usage:
#   attest-node.sh NODE [EXPECTED_DIGEST]   attest one node
#   attest-node.sh --lint                   offline: gate + stub + chain, no cluster
#
# Env:
#   ATTEST_SCHEDULE_FILE   schedule body path (attestation block)
#   EVIDENCE_FILE          the same append-only JSONL chain reconcile.sh writes
#   STUB_ATTEST_RESULT     pass|fail — the stub attestor verdict (test hook)
#   ATTEST_CMD             prod attestor command (exit 0 = verified); overrides the stub
set -euo pipefail

SCHEDULE_FILE="${ATTEST_SCHEDULE_FILE:-/etc/lending/schedule.yaml}"
EVIDENCE_FILE="${EVIDENCE_FILE:-/var/lib/lending/evidence.jsonl}"
log() { echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) level=$1 component=attest-node ${*:2}"; }
sha256h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# append_evidence NODE RESULT DIGEST DURATION — one hash-chained record, same
# chain and scheme as reconcile.sh emit_evidence (R14): hash = sha256(prev+rec).
append_evidence() {
  local node="$1" result="$2" digest="$3" dur="$4" ts prev rec hash
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$EVIDENCE_FILE")" 2>/dev/null || true
  prev=""
  [ -s "$EVIDENCE_FILE" ] && prev="$(tail -1 "$EVIDENCE_FILE" | jq -r '.hash // ""' 2>/dev/null || echo "")"
  rec="$(jq -cn --arg ts "$ts" --arg n "$node" --arg a "$result" --arg d "$digest" --arg dur "$dur" --arg p "$prev" \
    '{ts:$ts,node:$n,event:"attest",attestation:$a,image_digest:$d,attest_seconds:($dur|tonumber),prev_hash:$p}')"
  hash="$(printf '%s' "$prev$rec" | sha256h)"
  jq -cn --argjson r "$rec" --arg h "$hash" '$r + {hash:$h}' >>"$EVIDENCE_FILE"
}

# run_attestor EXPECTED_DIGEST -> exit 0 verified / non-zero failed, echoes digest.
run_attestor() {
  if [ -n "${ATTEST_CMD:-}" ]; then
    local d; d="$("$ATTEST_CMD" "${1:-}" 2>/dev/null)"; local rc=$?
    echo "${d:-${1:-unknown}}"; return $rc
  fi
  echo "${1:-sha256:stub-digest}"
  [ "${STUB_ATTEST_RESULT:-pass}" = pass ]
}

enabled() { [ "$(yq -r '.attestation.enabled // false' "$SCHEDULE_FILE")" = "true" ]; }

attest_one() {
  local node="$1" expect="${2:-$(yq -r '.attestation.expectedImageDigest // ""' "$SCHEDULE_FILE")}"
  if ! enabled; then
    log info action=attest_skip node="$node" msg="attestation disabled (pass-1: records stay not-enforced) — set attestation.enabled=true to enforce"
    return 0
  fi
  local start end dur digest result
  start="$(date +%s)"
  if digest="$(run_attestor "$expect")"; then result=verified; else result=failed; fi
  end="$(date +%s)"; dur=$((end - start))
  # The attest-stage duration metric (bridged to lending_attest_duration_seconds,
  # which populates rts_attest_seconds:p95). Logged, like the drain stages.
  log info action=attest node="$node" attestation="$result" image_digest="$digest" attest_seconds="$dur"
  append_evidence "$node" "$result" "$digest" "$dur"
  [ "$result" = verified ]
}

# --- offline lint ------------------------------------------------------------
if [ "${1:-}" = "--lint" ]; then
  command -v jq >/dev/null 2>&1 || { echo "LINT FAIL: jq" >&2; exit 1; }
  command -v yq >/dev/null 2>&1 || { echo "LINT FAIL: yq" >&2; exit 1; }
  SF="$(mktemp)"; EV="$(mktemp)"; EVIDENCE_FILE="$EV"; SCHEDULE_FILE="$SF"
  # disabled → no-op, no record written
  printf 'attestation:\n  enabled: false\n' >"$SF"; : >"$EV"
  attest_one node-x >/dev/null
  [ ! -s "$EV" ] || { echo "LINT FAIL: disabled must write no record" >&2; exit 1; }
  # enabled + stub pass → verified record with a digest
  printf 'attestation:\n  enabled: true\n  expectedImageDigest: "sha256:abc"\n' >"$SF"
  STUB_ATTEST_RESULT=pass attest_one node-x >/dev/null || { echo "LINT FAIL: stub pass should verify" >&2; exit 1; }
  jq -e 'select(.attestation=="verified") | select(.image_digest=="sha256:abc")' "$EV" >/dev/null \
    || { echo "LINT FAIL: verified record missing digest" >&2; exit 1; }
  # enabled + stub fail → failed record, non-zero
  STUB_ATTEST_RESULT=fail attest_one node-y >/dev/null && { echo "LINT FAIL: stub fail must be non-zero" >&2; exit 1; }
  tail -1 "$EV" | jq -e 'select(.attestation=="failed")' >/dev/null || { echo "LINT FAIL: failed record not written" >&2; exit 1; }
  echo "ATTEST-NODE LINT OK"
  exit 0
fi

# --- main --------------------------------------------------------------------
[ $# -ge 1 ] || { log error msg="usage: attest-node.sh NODE [EXPECTED_DIGEST] | --lint"; exit 2; }
command -v jq >/dev/null 2>&1 || { log error msg="jq not installed"; exit 1; }
command -v yq >/dev/null 2>&1 || { log error msg="yq not installed"; exit 1; }
attest_one "$1" "${2:-}"
