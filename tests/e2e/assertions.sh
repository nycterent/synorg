#!/usr/bin/env bash
# assertions.sh — e2e physics + game-day assertions (U7, R3). Sourced by
# tests/e2e/run.sh --test; not executable on its own.
#
# Six assertions, each a function with bounded timeouts and an explicit
# PASS/FAIL line. None can pass vacuously (plan R6): an empty query result, a
# missing node, or an absent metric is a FAIL, never a skip —
#   1. lend                 — a lendable-pool node carries the lent taint and a
#                             training pod actually borrows onto it
#   2. reclaim-ahead-of-ramp— a driven schedule + synthetic inference ramp;
#                             reclaim completes BEFORE the ramp needs capacity
#   3. scrub                — the reclaimed node's nodeclaim is deleted and the
#                             replacement has a NEW EC2 instance-id (old vs new
#                             recorded; equal id = VRAM not reset, node-scrub.md)
#   4. rejoin-under-p95     — render_start_seconds:p95:reclaim_window holds the
#                             gate while the node returns (runbooks/game-day.md)
#   5. game-day-storm       — the storm scenarios from rehearsal/scenarios.yaml
#                             pass their passGates, repeatRuns times
#   6. ledger               — zero net capacity release (entry snapshot ==
#                             exit reading; capacity-carve.md)
#
# Schedule driving: the lend/reclaim clock is driven by patching the LIVE
# lending-schedule ConfigMap to a compressed rehearsal timeline (the packet's
# "direct patch" path). This is a rehearsal-only exception to the git-only
# write path (KTD5): the original schedule is saved first and restored after.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "assertions.sh is sourced by tests/e2e/run.sh --test — do not execute directly" >&2
  exit 2
fi

# --- Tunables (env-overridable; every wait is bounded) -----------------------
E2E_LEND_TIMEOUT="${E2E_LEND_TIMEOUT:-900}"        # s: window open -> lent taint + borrow pod
E2E_RAMP_MINUTES="${E2E_RAMP_MINUTES:-15}"         # rehearsal productionRampAt = now + this
E2E_WAVE_OFFSETS="${E2E_WAVE_OFFSETS:-5 8 11}"     # minutes from now for waves 1..3
E2E_SCRUB_TIMEOUT="${E2E_SCRUB_TIMEOUT:-1200}"     # s: nodeclaim delete -> fresh node Ready
E2E_SCENARIO_SETTLE="${E2E_SCENARIO_SETTLE:-600}"  # s of storm load before gate evaluation
E2E_SCENARIOS="${E2E_SCENARIOS:-compressed-reclaim storm-all-at-once}"
E2E_PROM_LOCAL_PORT="${E2E_PROM_LOCAL_PORT:-19090}"
E2E_PEAK_RPS="${E2E_PEAK_RPS:-4000}"
E2E_TARGET_URL="${E2E_TARGET_URL:-http://inference.pilot.svc.cluster.local/render}"

SCHEDULE_ORIG="$E2E_STATE_DIR/schedule-orig.yaml"
SCRUB_STATE="$E2E_STATE_DIR/scrub-old-identity.txt"
SCENARIOS_INNER="$E2E_STATE_DIR/scenarios-inner.yaml"

# --- Helpers -----------------------------------------------------------------
k() { kubectl --context "$PILOT_CONTEXT" "$@"; }

# wait_until DESC TIMEOUT_S PREDICATE... — bounded poll; rc=1 on timeout.
wait_until() {
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  until "$@"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "  timeout: ${timeout}s elapsed waiting for: $desc" >&2
      return 1
    fi
    sleep 10
  done
}

# Prometheus read-API (same series as runbooks/game-day.md). E2E_PROM points at
# a reachable endpoint; otherwise a port-forward to svc/prometheus is opened.
PROM="${E2E_PROM:-}"
PROM_PF_PID=""
prom_ready() { curl -sfG "$PROM/api/v1/query" --data-urlencode 'query=up' >/dev/null 2>&1; }
prom_start() {
  [ -n "$PROM" ] && { prom_ready || { echo "  E2E_PROM=$PROM not answering" >&2; return 1; }; return 0; }
  k -n observability port-forward svc/prometheus "$E2E_PROM_LOCAL_PORT:9090" >/dev/null 2>&1 &
  PROM_PF_PID=$!
  PROM="http://127.0.0.1:$E2E_PROM_LOCAL_PORT"
  wait_until "prometheus read-API answering (evidence plane, U9)" 60 prom_ready
}
prom_stop() { [ -n "$PROM_PF_PID" ] && { kill "$PROM_PF_PID" 2>/dev/null || true; PROM_PF_PID=""; }; return 0; }
# Q PROMQL — first sample value, or empty (empty is always a FAIL upstream).
Q() { curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'; }

# Schedule targets, read from the LIVE ConfigMap (what the controller reads).
live_schedule() { k -n lending get cm lending-schedule -o jsonpath='{.data.schedule\.yaml}'; }
LENT_TAINT_KEY=""       # e.g. lending.synorg.io/lent
LENDABLE_POOL=""        # e.g. gpu-lendable
load_schedule_targets() {
  local sched
  sched="$(live_schedule)" || return 1
  LENDABLE_POOL="$(yq -r '.targets.lendablePool' <<<"$sched")"
  local taint; taint="$(yq -r '.targets.lentTaint' <<<"$sched")"
  LENT_TAINT_KEY="${taint%%=*}"
  [ -n "$LENDABLE_POOL" ] && [ -n "$LENT_TAINT_KEY" ]
}

lent_nodes() {
  k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -r --arg key "$LENT_TAINT_KEY" \
        '.items[] | select((.spec.taints // []) | any(.key == $key)) | .metadata.name'
}
has_lent_node() { [ -n "$(lent_nodes)" ]; }
no_lent_node() { [ -z "$(lent_nodes)" ]; }

# hhmm_plus TZ MINUTES — wall-clock HH:MM offset from now in TZ (GNU + BSD date).
hhmm_plus() {
  local tz="$1" mins="$2"
  if TZ="$tz" date -d "$mins minutes" +%H:%M 2>/dev/null; then return 0; fi
  # BSD date: an unsigned -v value SETS the field instead of adjusting it, so
  # force an explicit sign for positive offsets.
  case "$mins" in -*|+*) : ;; *) mins="+$mins" ;; esac
  TZ="$tz" date -v "${mins}M" +%H:%M
}

# drive_schedule_now RAMP_MINUTES — compress the live schedule onto the next
# RAMP_MINUTES: window opens now, waves at $E2E_WAVE_OFFSETS, ramp at the end.
# Saves the original once; restore_schedule puts it back.
drive_schedule_now() {
  local ramp_min="$1" tz sched w1 w2 w3
  sched="$(live_schedule)" || return 1
  [ -f "$SCHEDULE_ORIG" ] || printf '%s\n' "$sched" > "$SCHEDULE_ORIG"
  tz="$(yq -r '.timezone' <<<"$sched")"
  read -r w1 w2 w3 <<<"$E2E_WAVE_OFFSETS"
  printf '%s\n' "$sched" | yq \
    ".windows[0].opensAt = \"$(hhmm_plus "$tz" -1)\"
     | .windows[0].closesAt = \"$(hhmm_plus "$tz" "$w3")\"
     | .productionRampAt = \"$(hhmm_plus "$tz" "$ramp_min")\"
     | .reclaimWaves[0].startsAt = \"$(hhmm_plus "$tz" "$w1")\"
     | .reclaimWaves[1].startsAt = \"$(hhmm_plus "$tz" "$w2")\"
     | .reclaimWaves[2].startsAt = \"$(hhmm_plus "$tz" "$w3")\"
     | .borrowingLimitCurve[0].at = \"$(hhmm_plus "$tz" -1)\"
     | .borrowingLimitCurve[1].at = \"$(hhmm_plus "$tz" "$w1")\"
     | .borrowingLimitCurve[2].at = \"$(hhmm_plus "$tz" "$w2")\"
     | .borrowingLimitCurve[3].at = \"$(hhmm_plus "$tz" "$w3")\"" \
    > "$E2E_STATE_DIR/schedule-rehearsal.yaml"
  k -n lending create configmap lending-schedule \
      --from-file=schedule.yaml="$E2E_STATE_DIR/schedule-rehearsal.yaml" \
      --dry-run=client -o yaml | k replace -f - >/dev/null
  echo "  schedule driven: window open now, waves +${w1}/+${w2}/+${w3}m, ramp +${ramp_min}m (orig saved)"
}

restore_schedule() {
  [ -f "$SCHEDULE_ORIG" ] || return 0
  k -n lending create configmap lending-schedule \
      --from-file=schedule.yaml="$SCHEDULE_ORIG" \
      --dry-run=client -o yaml | k replace -f - >/dev/null || return 1
  echo "  schedule restored to the git-controlled original"
}

# Synthetic inference ramp — the game-day loadgen (runbooks/game-day.md Step 1/3).
loadgen_start() {
  local ramp_min="$1"
  k apply -f rehearsal/scenarios.yaml -f rehearsal/loadgen.yaml >/dev/null
  k -n rehearsal set env deploy/game-day-loadgen \
    PEAK_RPS="$E2E_PEAK_RPS" RAMP_MINUTES="$ramp_min" TARGET_URL="$E2E_TARGET_URL" >/dev/null
  k -n rehearsal scale deploy/game-day-loadgen --replicas=1 >/dev/null
}
loadgen_stop() { k -n rehearsal scale deploy/game-day-loadgen --replicas=0 >/dev/null 2>&1 || true; }

# Training workload that borrows onto lent nodes (fills the reclaim with real
# work — an empty reclaim proves nothing, game-day.md Step 2).
training_submit() {
  helm template e2e-training charts/training-job -f charts/training-job/ci/basic-training.yaml \
    | k apply -f - >/dev/null
}
training_delete() {
  helm template e2e-training charts/training-job -f charts/training-job/ci/basic-training.yaml \
    | k delete -f - --ignore-not-found >/dev/null 2>&1 || true
}
training_pod_on_lent_node() {
  local nodes; nodes="$(lent_nodes)"
  [ -n "$nodes" ] || return 1
  k get pods -A -o json | jq -e --arg nodes "$nodes" '
    [.items[]
     | select(.status.phase == "Running")
     | select(.metadata.name | startswith("e2e-training"))
     | select(.spec.nodeName as $n | ($nodes | split("\n") | index($n)))
    ] | length > 0' >/dev/null
}

# --- 1. lend -----------------------------------------------------------------
assert_lend() {
  step "assert 1/6: lend — lendable node tainted lent + training borrows onto it"
  load_schedule_targets || { echo "FAIL: lend — cannot read live lending-schedule targets"; return 1; }
  drive_schedule_now "$E2E_RAMP_MINUTES" || { echo "FAIL: lend — could not drive the schedule"; return 1; }
  training_submit || { echo "FAIL: lend — could not submit the training workload"; return 1; }
  wait_until "a $LENDABLE_POOL node carrying $LENT_TAINT_KEY" "$E2E_LEND_TIMEOUT" has_lent_node \
    || { echo "FAIL: lend — no node from pool '$LENDABLE_POOL' was tainted lent within ${E2E_LEND_TIMEOUT}s"; return 1; }
  echo "  lent nodes:"; lent_nodes | sed 's/^/    /'
  wait_until "a Running e2e-training pod on a lent node" "$E2E_LEND_TIMEOUT" training_pod_on_lent_node \
    || { echo "FAIL: lend — node lent but no training pod borrowed onto it within ${E2E_LEND_TIMEOUT}s"; return 1; }
  # Record the identity that must NOT survive the scrub (node-scrub.md Step 0).
  local node old_instance old_nodeclaim
  node="$(lent_nodes | head -1)"
  old_instance="$(k get node "$node" -o jsonpath='{.spec.providerID}')"
  old_nodeclaim="$(k get nodeclaim -o json \
    | jq -r --arg n "$node" '.items[] | select(.status.nodeName == $n) | .metadata.name')"
  { [ -n "$old_instance" ] && [ -n "$old_nodeclaim" ]; } \
    || { echo "FAIL: lend — cannot record old instance identity for node '$node' (needed by the scrub assertion)"; return 1; }
  printf '%s %s %s\n' "$node" "$old_instance" "$old_nodeclaim" > "$SCRUB_STATE"
  echo "PASS: lend — $node lent and borrowed onto (old identity recorded: ${old_instance##*/})"
}

# --- 2. reclaim ahead of ramp ------------------------------------------------
assert_reclaim_ahead_of_ramp() {
  step "assert 2/6: reclaim-ahead-of-ramp — waves finish before the synthetic ramp needs capacity"
  [ -n "$LENDABLE_POOL" ] || { echo "FAIL: reclaim — schedule targets not loaded (did lend run?)"; return 1; }
  has_lent_node || { echo "FAIL: reclaim — nothing is lent, so there is nothing to reclaim (no vacuous pass)"; return 1; }
  local ramp_epoch=$(( $(date +%s) + E2E_RAMP_MINUTES * 60 ))
  loadgen_start "$E2E_RAMP_MINUTES" || { echo "FAIL: reclaim — could not start the synthetic inference ramp"; return 1; }
  # The driven schedule (assert_lend) already placed the waves inside the ramp
  # window; the controller must return every lent node before the ramp lands.
  wait_until "all lent taints cleared (reclaim complete)" $(( E2E_RAMP_MINUTES * 60 + 300 )) no_lent_node \
    || { echo "FAIL: reclaim — lent nodes remain after ramp + grace"; return 1; }
  local done_epoch; done_epoch="$(date +%s)"
  if [ "$done_epoch" -ge "$ramp_epoch" ]; then
    echo "FAIL: reclaim finished $(( done_epoch - ramp_epoch ))s AFTER the ramp deadline — the render path would have queued"
    return 1
  fi
  echo "PASS: reclaim-ahead-of-ramp — completed $(( ramp_epoch - done_epoch ))s before the ramp deadline"
}

# --- 3. scrub: new instance-id -----------------------------------------------
nodeclaim_gone() { ! k get nodeclaim "$1" >/dev/null 2>&1; }
fresh_pool_node() {  # PREDICATE: some Ready pool node has providerID != $1
  k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -e --arg old "$1" '
        [.items[]
         | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))
         | select(.spec.providerID != $old and .spec.providerID != null)
        ] | length > 0' >/dev/null
}
assert_scrub_new_instance() {
  step "assert 3/6: scrub — reclaimed nodeclaim deleted, replacement has a NEW EC2 instance-id"
  [ -s "$SCRUB_STATE" ] || { echo "FAIL: scrub — no recorded old identity (lend assertion must pass first)"; return 1; }
  local node old_instance old_nodeclaim
  read -r node old_instance old_nodeclaim < "$SCRUB_STATE"
  wait_until "nodeclaim $old_nodeclaim deleted (instance terminated)" "$E2E_SCRUB_TIMEOUT" \
    nodeclaim_gone "$old_nodeclaim" \
    || { echo "FAIL: scrub — nodeclaim '$old_nodeclaim' still exists; the reclaimed node was never scrubbed"; return 1; }
  wait_until "a fresh Ready node in $LENDABLE_POOL" "$E2E_SCRUB_TIMEOUT" fresh_pool_node "$old_instance" \
    || { echo "FAIL: scrub — no replacement node with a different instance-id within ${E2E_SCRUB_TIMEOUT}s"; return 1; }
  local new_instance
  new_instance="$(k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -r --arg old "$old_instance" \
        '[.items[] | .spec.providerID | select(. != null and . != $old)][0]')"
  # Equal instance-id would mean VRAM was never reset — node-scrub.md abort case.
  if [ "$new_instance" = "$old_instance" ] || [ -z "$new_instance" ]; then
    echo "FAIL: scrub — replacement instance-id equals the old one (VRAM not reset; node-scrub.md abort)"
    return 1
  fi
  echo "  old instance: ${old_instance##*/}  (node $node, nodeclaim $old_nodeclaim)"
  echo "  new instance: ${new_instance##*/}"
  echo "PASS: scrub — instance discarded and recovered fresh (old != new)"
}

# --- 4. rejoin under the render-start p95 gate -------------------------------
assert_rejoin_under_p95_gate() {
  step "assert 4/6: rejoin — render_start p95 holds the gate through reclaim + rejoin"
  local target p95
  target="$(yq -r '.data["scenarios.yaml"]' rehearsal/scenarios.yaml \
    | yq -r '.parameters.renderStartP95TargetSeconds')"
  [ -n "$target" ] && [ "$target" != "null" ] \
    || { echo "FAIL: rejoin — no renderStartP95TargetSeconds in rehearsal/scenarios.yaml"; return 1; }
  # Same series as runbooks/game-day.md Step 5 — the reclaim-window-scoped p95.
  p95="$(Q 'render_start_seconds:p95:reclaim_window')"
  if [ -z "$p95" ]; then
    echo "FAIL: rejoin — render_start_seconds:p95:reclaim_window returned no samples (an unmeasured run has no verdict, game-day.md)"
    return 1
  fi
  if ! awk -v v="$p95" -v t="$target" 'BEGIN { exit !(v + 0 <= t + 0) }'; then
    echo "FAIL: rejoin — render-start p95 ${p95}s breached the ${target}s gate during reclaim/rejoin"
    return 1
  fi
  echo "PASS: rejoin — render-start p95 ${p95}s <= ${target}s gate"
}

# --- 5. game-day storm scenarios ---------------------------------------------
run_scenario_once() {  # SCENARIO RUN_NO — one driven run + passGates evaluation
  local scenario="$1" run_no="$2" rc=0
  echo "  scenario '$scenario' run $run_no: driving reclaim + storm load (${E2E_SCENARIO_SETTLE}s settle)"
  drive_schedule_now "$E2E_RAMP_MINUTES" || return 1
  loadgen_start "$E2E_RAMP_MINUTES" || return 1
  sleep "$E2E_SCENARIO_SETTLE"
  local metric op param threshold value
  while IFS=$'\t' read -r metric op param; do
    threshold="$(yq -r ".parameters.$param" "$SCENARIOS_INNER")"
    value="$(Q "$metric")"
    if [ -z "$value" ]; then
      echo "  FAIL gate: $metric returned no samples (no vacuous pass)"; rc=1; continue
    fi
    if awk -v v="$value" -v t="$threshold" -v op="$op" \
         'BEGIN { if (op == ">=") exit !(v + 0 >= t + 0); exit !(v + 0 <= t + 0) }'; then
      echo "  gate OK:   $metric = $value $op $threshold ($param)"
    else
      echo "  FAIL gate: $metric = $value violates $op $threshold ($param)"; rc=1
    fi
  done < <(yq -r ".scenarios[] | select(.name == \"$scenario\") | .passGates[] | [.metric, .comparison, .param] | @tsv" "$SCENARIOS_INNER")
  loadgen_stop
  return "$rc"
}
assert_game_day_storm() {
  step "assert 5/6: game-day storm — scenarios from rehearsal/scenarios.yaml pass their gates"
  yq -r '.data["scenarios.yaml"]' rehearsal/scenarios.yaml > "$SCENARIOS_INNER" \
    || { echo "FAIL: game-day — cannot extract scenarios from rehearsal/scenarios.yaml"; return 1; }
  local repeat_runs; repeat_runs="${E2E_REPEAT_RUNS:-$(yq -r '.parameters.repeatRuns' "$SCENARIOS_INNER")}"
  local scenario run_no failed=0
  for scenario in $E2E_SCENARIOS; do
    if ! yq -e ".scenarios[] | select(.name == \"$scenario\")" "$SCENARIOS_INNER" >/dev/null 2>&1; then
      echo "FAIL: game-day — scenario '$scenario' not found in rehearsal/scenarios.yaml"; failed=1; continue
    fi
    # repeatRuns per game-day.md: a single green run is not a pass.
    for run_no in $(seq 1 "$repeat_runs"); do
      run_scenario_once "$scenario" "$run_no" || { failed=1; break; }
    done
  done
  [ "$failed" -eq 0 ] || { echo "FAIL: game-day storm — at least one scenario gate breached (see gate lines above)"; return 1; }
  echo "PASS: game-day storm — scenarios [$E2E_SCENARIOS] held every passGate across $repeat_runs run(s)"
}

# --- 6. ledger: zero net capacity release ------------------------------------
assert_ledger_zero_net_release() {
  step "assert 6/6: ledger — zero net capacity release (capacity-carve.md invariant)"
  [ -f "$LEDGER_ENTRY_FILE" ] || { echo "FAIL: ledger — no entry snapshot to compare against"; return 1; }
  local now_file="$E2E_STATE_DIR/ledger-test.txt"
  ledger_read > "$now_file" || { echo "FAIL: ledger — cannot read reservation state"; return 1; }
  if ! diff -u "$LEDGER_ENTRY_FILE" "$now_file"; then
    echo "FAIL: ledger — reservation totals/held drifted during the run (capacity released or lost)"
    return 1
  fi
  echo "PASS: ledger — reservation totals/held identical to the entry snapshot"
}

# --- Runner ------------------------------------------------------------------
# e2e_assert_all — run every assertion in order, keep going after a failure so
# one run reports the full physics picture; rc!=0 if any failed. Cleanup
# (loadgen off, training deleted, schedule restored, port-forward closed)
# always runs, pass or fail.
e2e_assert_all() {
  local failed=0 a
  prom_start || { echo "FAIL: evidence plane unreachable — an unmeasured run has no verdict (game-day.md abort)"; return 1; }
  for a in assert_lend assert_reclaim_ahead_of_ramp assert_scrub_new_instance \
           assert_rejoin_under_p95_gate assert_game_day_storm assert_ledger_zero_net_release; do
    "$a" || failed=$(( failed + 1 ))
  done
  step "assertions cleanup (loadgen, training workload, schedule, port-forward)"
  loadgen_stop
  training_delete
  restore_schedule || echo "  WARNING: could not restore the original schedule — restore it manually from $SCHEDULE_ORIG" >&2
  prom_stop
  echo
  if [ "$failed" -gt 0 ]; then
    echo "ASSERTIONS: $failed of 6 FAILED"
    return 1
  fi
  echo "ASSERTIONS: 6 of 6 PASSED"
}
