#!/usr/bin/env bash
# governor_test.sh — R6/R26/R27 RTS-governor loop. Pure control-loop math: no
# cluster needed, so it runs the same in the ladder and offline (--lint). Injects
# RTS p95 against a synthetic governor config and asserts the one-step proposal.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GOV="$ROOT/controllers/governor/rts-governor.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v yq >/dev/null 2>&1 || fail "yq not installed"

bash "$GOV" --lint || fail "rts-governor --lint failed (loop math)"
pass "governor loop math (decide + step, hold band, clamps)"

SF="$(mktemp)"
# Start below max so both shrink AND expand show real movement.
cat >"$SF" <<EOF
governor:
  rtsP95BudgetSeconds: 600
  holdBandSeconds: 60
  ceilingPct: 80
  ceilingStepPct: 10
  wavePct: 80
  waveStepPct: 10
EOF
# Capture then grep — never grep -q inside a pipe under pipefail (grep's early
# exit SIGPIPEs the governor, failing the pipeline on the multi-line hold path).
run() { GOVERNOR_SCHEDULE_FILE="$SF" GOVERNOR_RTS_P95_SECONDS="$1" bash "$GOV" 2>&1; }

O="$(run 700)"; grep -q 'decision=shrink ceiling=80->70 wave=80->70' <<<"$O" \
  || fail "RTS over budget must shrink one step: $O"
pass "RTS over budget → shrink one step (ceiling+wave 80→70)"

O="$(run 500)"; grep -q 'decision=expand ceiling=80->90 wave=80->90' <<<"$O" \
  || fail "RTS under budget must expand one step: $O"
pass "RTS under budget → expand one step (ceiling+wave 80→90)"

O="$(run 600)"; grep -q 'decision=hold' <<<"$O" \
  || fail "RTS within the hold band must hold: $O"
O="$(run 640)"; grep -q 'decision=hold' <<<"$O" \
  || fail "RTS inside +holdBand must hold (no oscillation): $O"
pass "RTS within hold band → no change (R27 damping)"

# --write emits a PR-landable proposal (R25: propose, never mutate the cluster).
WF="$(mktemp)"
GOVERNOR_SCHEDULE_FILE="$SF" GOVERNOR_RTS_P95_SECONDS=700 bash "$GOV" --write "$WF" >/dev/null
[ "$(yq -r '.governor.ceilingPct' "$WF")" = 70 ] \
  || fail "--write did not emit the proposed next ceiling: $(cat "$WF")"
pass "--write emits a PR-landable next-window proposal"

echo "GOVERNOR OK"
