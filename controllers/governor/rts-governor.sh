#!/usr/bin/env bash
# rts-governor.sh (R6/R26/R27) — the return-to-service governor. Reads RTS p95,
# compares it to the budget with a hold band, and proposes a ONE-STEP change to
# the lending ceiling and reclaim wave size for the NEXT window.
#
# Three invariants make this a governor, not a nightly retrospective:
#   R26 — control period is ONE lending cycle. The proposal applies to the NEXT
#         window, never the one in flight; in-flight protection is the owner
#         floor and drain budget, not this loop.
#   R27 — ONE step per period, with a HOLD BAND: inside ±holdBand of the budget,
#         nothing changes. This damps the feedback (wave size feeds RTS, which
#         feeds wave size) so the loop reacts to real degradation, not its own
#         last move.
#   R6  — RTS over budget SHRINKS lending (lower ceiling, smaller waves); RTS
#         comfortably under budget EXPANDS it. Both knobs move together.
#
# PR-only actuation (R25): the governor PROPOSES — it prints the decision and the
# next ceiling/wave values, or writes them to a patch file for a PR. It never
# writes to the cluster. A human or agent lands the proposal by PR before the
# next cycle.
#
# The RTS p95 is injected for tests and read from the SLO API in prod. Magnitudes
# are pilot-tuned; the loop MATH here is complete and pilot-independent.
#
# Usage:
#   rts-governor.sh                 read schedule + RTS, print the proposal
#   rts-governor.sh --write FILE    also write the proposed governor block to FILE (for a PR)
#   rts-governor.sh --lint          offline: the loop math, no schedule/RTS source
#
# Env:
#   GOVERNOR_SCHEDULE_FILE   schedule ConfigMap-body path (governor block lives here)
#   GOVERNOR_RTS_P95_SECONDS inject the current RTS p95 (test hook; prod reads the SLO API)
set -euo pipefail

SCHEDULE_FILE="${GOVERNOR_SCHEDULE_FILE:-/etc/lending/schedule.yaml}"
log() { echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) level=$1 component=rts-governor ${*:2}"; }

clamp() { local v="$1" lo="$2" hi="$3"; [ "$v" -lt "$lo" ] && v="$lo"; [ "$v" -gt "$hi" ] && v="$hi"; echo "$v"; }

# decide RTS BUDGET BAND -> shrink | expand | hold. Integer seconds.
decide() {
  local rts="$1" budget="$2" band="$3"
  if   [ "$rts" -gt "$((budget + band))" ]; then echo shrink
  elif [ "$rts" -lt "$((budget - band))" ]; then echo expand
  else echo hold; fi
}

# step VALUE STEP DIR MIN MAX -> new value. shrink lowers, expand raises, hold keeps.
step() {
  local v="$1" s="$2" dir="$3" lo="$4" hi="$5"
  case "$dir" in
    shrink) v=$((v - s)) ;;
    expand) v=$((v + s)) ;;
    hold)   : ;;
  esac
  clamp "$v" "$lo" "$hi"
}

# --- offline lint: the loop math, no cluster/schedule -------------------------
if [ "${1:-}" = "--lint" ]; then
  [ "$(decide 700 600 60)" = shrink ] || { echo "LINT FAIL: 700 > 660 must shrink" >&2; exit 1; }
  [ "$(decide 500 600 60)" = expand ] || { echo "LINT FAIL: 500 < 540 must expand" >&2; exit 1; }
  [ "$(decide 600 600 60)" = hold ]   || { echo "LINT FAIL: 600 within band must hold" >&2; exit 1; }
  [ "$(decide 650 600 60)" = hold ]   || { echo "LINT FAIL: 650 inside +band must hold" >&2; exit 1; }
  [ "$(step 100 10 shrink 0 100)" = 90 ]  || { echo "LINT FAIL: shrink one step 100->90" >&2; exit 1; }
  [ "$(step 100 10 expand 0 100)" = 100 ] || { echo "LINT FAIL: expand clamps at max 100" >&2; exit 1; }
  [ "$(step 5 10 shrink 0 100)" = 0 ]     || { echo "LINT FAIL: shrink clamps at min 0" >&2; exit 1; }
  [ "$(step 50 10 hold 0 100)" = 50 ]     || { echo "LINT FAIL: hold keeps value" >&2; exit 1; }
  echo "RTS-GOVERNOR LINT OK"
  exit 0
fi

# --- main --------------------------------------------------------------------
WRITE=""
[ "${1:-}" = "--write" ] && { WRITE="${2:-}"; [ -n "$WRITE" ] || { log error msg="--write needs a path"; exit 2; }; }
command -v yq >/dev/null 2>&1 || { log error msg="yq not installed"; exit 1; }

g() { yq -r ".governor.$1 // \"$2\"" "$SCHEDULE_FILE"; }
budget="$(g rtsP95BudgetSeconds 600)"; band="$(g holdBandSeconds 60)"
ceil="$(g ceilingPct 100)"; ceilStep="$(g ceilingStepPct 10)"
wave="$(g wavePct 100)";    waveStep="$(g waveStepPct 10)"

rts="${GOVERNOR_RTS_P95_SECONDS:-}"
if [ -z "$rts" ]; then
  log warn msg="no RTS p95 source (set GOVERNOR_RTS_P95_SECONDS or wire the SLO API) — cannot govern this cycle"
  exit 0
fi
rts="${rts%.*}"

dir="$(decide "$rts" "$budget" "$band")"
next_ceil="$(step "$ceil" "$ceilStep" "$dir" 0 100)"
next_wave="$(step "$wave" "$waveStep" "$dir" 0 100)"

log info action=governor_proposal rts_p95="$rts" budget="$budget" band="$band" decision="$dir" \
  ceiling="$ceil->$next_ceil" wave="$wave->$next_wave" applies=next-window note="one step per cycle (R26/R27); PR to actuate (R25)"

if [ "$dir" = hold ]; then
  log info action=governor_hold msg="RTS p95 within the hold band — no change proposed"
elif [ -n "$WRITE" ]; then
  cat >"$WRITE" <<EOF
# Proposed by rts-governor for the NEXT window (RTS p95 ${rts}s, budget ${budget}s, decision: ${dir}).
# Land by PR (R25). One step per cycle (R27).
governor:
  ceilingPct: ${next_ceil}
  wavePct: ${next_wave}
EOF
  log info action=governor_wrote file="$WRITE"
fi
