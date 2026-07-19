#!/usr/bin/env bash
# assertions.sh — e2e physics + game-day assertions (U7, R3). Sourced by
# tests/e2e/run.sh --test; not executable on its own.
#
# Eight assertions, each a function with bounded timeouts and an explicit
# PASS/FAIL line. None can pass vacuously (plan R6): an empty query result, a
# missing node, or an absent metric is a FAIL, never a skip —
#   1. lend                 — a lendable-pool node carries the lent taint and a
#                             training pod actually borrows onto it
#   2. reclaim-ahead-of-ramp— a driven schedule + synthetic inference ramp;
#                             reclaim completes BEFORE the ramp needs capacity.
#                             The driven window closes AFTER the ramp deadline,
#                             so inside the measured window only reclaimWaves
#                             can clear taints, and the controller's own
#                             wave-firing + NodeClaim-deletion log lines are
#                             required as positive evidence — a dead wave
#                             schedule cannot be bailed out by the close path
#   3. borrower-drain       — inside the reclaim phase every borrowing
#                             Workload is deactivated and drained-annotated
#                             (ADR 0008: no tail-chase)
#   4. scrub                — the reclaimed node's nodeclaim is deleted and a
#                             replacement carries an EC2 instance-id OUTSIDE
#                             the lend-time pool snapshot (genuinely NEW
#                             instance — a pre-existing sibling never counts;
#                             equal id = VRAM not reset, node-scrub.md)
#   5. rejoin-under-p95     — render_start_seconds:p95:reclaim_window holds the
#                             gate while the node returns (runbooks/game-day.md)
#   6. game-day-storm       — the storm scenarios from rehearsal/scenarios.yaml
#                             pass their passGates, repeatRuns times
#   7. borrower-reactivation— after the window close exactly the drained
#                             Workloads are unmarked and reactivated
#   8. ledger               — zero net capacity release (entry snapshot ==
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
E2E_CLOSE_MINUTES="${E2E_CLOSE_MINUTES:-$(( E2E_RAMP_MINUTES + 5 ))}" # rehearsal closesAt = now + this;
                                                   # MUST be > E2E_RAMP_MINUTES so only waves can
                                                   # clear taints before the deadline (#19)
E2E_SCRUB_TIMEOUT="${E2E_SCRUB_TIMEOUT:-1200}"     # s: nodeclaim delete -> fresh node Ready
E2E_SCENARIO_SETTLE="${E2E_SCENARIO_SETTLE:-600}"  # s of storm load before gate evaluation
E2E_SCENARIOS="${E2E_SCENARIOS:-compressed-reclaim storm-all-at-once}"
E2E_PROM_LOCAL_PORT="${E2E_PROM_LOCAL_PORT:-19090}"
E2E_PEAK_RPS="${E2E_PEAK_RPS:-4000}"
# Release "inference" of the golden-service chart in ns pilot (run.sh
# standins_up): fullname is <release>-<chart>.
E2E_TARGET_URL="${E2E_TARGET_URL:-http://inference-golden-service.pilot.svc.cluster.local/render}"

SCHEDULE_ORIG="$E2E_STATE_DIR/schedule-orig.yaml"
SCRUB_STATE="$E2E_STATE_DIR/scrub-old-identity.txt"
POOL_ENTRY_IDS="$E2E_STATE_DIR/pool-entry-providerids.txt"  # all pool providerIDs at lend time (#20)
SCENARIOS_INNER="$E2E_STATE_DIR/scenarios-inner.yaml"
E2E_DRIVE_EPOCH=0       # set by drive_schedule_now; bounds the controller-log reads (#19)

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

# Prometheus read-API (same series as runbooks/game-day.md). Resolution order:
#   1. E2E_PROM — explicit endpoint override, must answer;
#   2. any Service in $E2E_PROM_NAMESPACE with a port 9090 (kube-prometheus-
#      stack names its Service <release>-kube-prometheus-prometheus, never
#      plain "prometheus" — same jq discovery as tests/smoke/smoke.sh);
#   3. the operator's headless prometheus-operated Service;
#   4. loud FAIL naming the namespace — no evidence plane, no verdict.
PROM="${E2E_PROM:-}"
PROM_PF_PID=""
E2E_PROM_NAMESPACE="${E2E_PROM_NAMESPACE:-observability}"
prom_ready() { curl -sfG "$PROM/api/v1/query" --data-urlencode 'query=up' >/dev/null 2>&1; }
prom_discover_svc() {
  k get svc -n "$E2E_PROM_NAMESPACE" -o json 2>/dev/null \
    | jq -r '[.items[] | select(any(.spec.ports[]?; .port == 9090))][0].metadata.name // empty'
}
prom_start() {
  [ -n "$PROM" ] && { prom_ready || { echo "  E2E_PROM=$PROM not answering" >&2; return 1; }; return 0; }
  local svc
  svc="$(prom_discover_svc)"
  if [ -z "$svc" ] && k -n "$E2E_PROM_NAMESPACE" get svc prometheus-operated >/dev/null 2>&1; then
    svc="prometheus-operated"
  fi
  if [ -z "$svc" ]; then
    echo "FAIL: no Prometheus Service (port 9090, nor prometheus-operated) in namespace '$E2E_PROM_NAMESPACE' — set E2E_PROM to a reachable endpoint or fix the evidence plane" >&2
    return 1
  fi
  k -n "$E2E_PROM_NAMESPACE" port-forward "svc/$svc" "$E2E_PROM_LOCAL_PORT:9090" >/dev/null 2>&1 &
  PROM_PF_PID=$!
  PROM="http://127.0.0.1:$E2E_PROM_LOCAL_PORT"
  if ! wait_until "prometheus read-API answering (evidence plane, U9)" 60 prom_ready; then
    prom_stop   # readiness timed out: reap the spawned port-forward, no leak
    return 1
  fi
}
# prom_stop — idempotent: unset or already-dead PID is a no-op.
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

# none_of_set_lent FILE — every node named in FILE has shed the lent taint
# (a deleted node counts as cleared). Scopes the reclaim verdict to the nodes
# that were lent when the assertion started: an admitted training workload
# re-pends after each wave drain, Karpenter re-provisions, and the still-open
# window re-lends the fresh node — nothing but the window close can clear
# those late lends (Kueue keeps an admitted workload admitted when the
# borrowingLimit shrinks). The ramp invariant is about the capacity that was
# OUT on loan, not about fresh borrows the close will collect.
none_of_set_lent() {
  local snapshot="$1" still
  still="$(lent_nodes)"
  [ -z "$still" ] && return 0
  ! grep -qxF -f "$snapshot" <<<"$still"
}

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
# RAMP_MINUTES: window opens now, waves at $E2E_WAVE_OFFSETS, ramp at the end,
# window close at $E2E_CLOSE_MINUTES. Saves the original once; restore_schedule
# puts it back.
#
# Ordering invariant (#19): waves < ramp deadline < closesAt. The close lands
# AFTER the deadline on purpose — since the close-as-reclaim fix the close path
# also reclaims, so a closesAt inside the window would let a dead wave schedule
# pass as "reclaim ahead of ramp". With this ordering, only reclaimWaves can
# clear lent taints before the deadline.
drive_schedule_now() {
  local ramp_min="$1" close_min="$E2E_CLOSE_MINUTES" tz sched w1 w2 w3
  sched="$(live_schedule)" || return 1
  [ -f "$SCHEDULE_ORIG" ] || printf '%s\n' "$sched" > "$SCHEDULE_ORIG"
  # Unconditional and idempotent: gating this on the orig-save skipped the
  # detach whenever a PRIOR run's schedule-orig.yaml survived in
  # $E2E_STATE_DIR (found live: second fixed run still failed lend because
  # the stale file made the first-drive guard a no-op).
  lending_sync_detach
  tz="$(yq -r '.timezone' <<<"$sched")"
  read -r w1 w2 w3 <<<"$E2E_WAVE_OFFSETS"
  if [ "$w3" -ge "$ramp_min" ] || [ "$close_min" -le "$ramp_min" ]; then
    echo "  drive_schedule_now: invalid rehearsal timeline — need waves ($E2E_WAVE_OFFSETS) < ramp (+${ramp_min}m) < close (+${close_min}m); fix E2E_WAVE_OFFSETS/E2E_RAMP_MINUTES/E2E_CLOSE_MINUTES" >&2
    return 1
  fi
  E2E_DRIVE_EPOCH="$(date +%s)"
  printf '%s\n' "$sched" | yq \
    ".windows[0].opensAt = \"$(hhmm_plus "$tz" -1)\"
     | .windows[0].closesAt = \"$(hhmm_plus "$tz" "$close_min")\"
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
  echo "  schedule driven: window open now, waves +${w1}/+${w2}/+${w3}m, ramp +${ramp_min}m, close +${close_min}m (orig saved)"
}

restore_schedule() {
  [ -f "$SCHEDULE_ORIG" ] || return 0
  k -n lending create configmap lending-schedule \
      --from-file=schedule.yaml="$SCHEDULE_ORIG" \
      --dry-run=client -o yaml | k replace -f - >/dev/null || return 1
  lending_sync_reattach
  echo "  schedule restored to the git-controlled original"
}

# --- pilot-lending sync detach (rehearsal-only, mirrors cheap-overlay) -------
# The driven schedule is a direct ConfigMap replace, and pilot-lending syncs
# with selfHeal — on the working GitOps path ArgoCD reverts the rehearsal
# schedule within seconds and the controller never sees a window (found live
# on the first synced run: every tick logged window_open=0 while the driver
# thought the window was open). Detach that ONE Application's automated sync
# for the rehearsal, exactly as the cheap overlay does for the sizing surface;
# re-attach on restore. Without a hub (or before the appsets exist) both are
# no-ops and direct replaces stick on their own.
kh() { kubectl --context "${MGMT_CONTEXT:-synorg-mgmt}" "$@"; }

lending_sync_detach() {
  kh -n argocd get application pilot-lending >/dev/null 2>&1 || return 0
  kh -n argocd patch applicationset regions --type=merge -p \
    '{"spec":{"ignoreApplicationDifferences":[{"jsonPointers":["/spec/syncPolicy"]}]}}' >/dev/null 2>&1 || true
  kh -n argocd patch application pilot-lending --type=merge -p \
    '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
  echo "  automated sync (selfHeal) OFF for pilot-lending — driven schedule holds for the rehearsal"
}

lending_sync_reattach() {
  kh -n argocd get application pilot-lending >/dev/null 2>&1 || return 0
  kh -n argocd patch application pilot-lending --type=merge -p \
    '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}' >/dev/null 2>&1 || true
  echo "  automated sync (selfHeal) restored for pilot-lending"
}

# Synthetic inference ramp — the game-day loadgen (runbooks/game-day.md Step 1/3).
loadgen_start() {
  local ramp_min="$1"
  k apply -f rehearsal/namespace.yaml -f rehearsal/scenarios.yaml -f rehearsal/loadgen.yaml >/dev/null
  k -n rehearsal set env deploy/game-day-loadgen \
    PEAK_RPS="$E2E_PEAK_RPS" RAMP_MINUTES="$ramp_min" TARGET_URL="$E2E_TARGET_URL" >/dev/null
  k -n rehearsal scale deploy/game-day-loadgen --replicas=1 >/dev/null
}
loadgen_stop() { k -n rehearsal scale deploy/game-day-loadgen --replicas=0 >/dev/null 2>&1 || true; }

# Training workload that borrows onto lent nodes (fills the reclaim with real
# work — an empty reclaim proves nothing, game-day.md Step 2).
# Stand-in values (tests/e2e/stand-ins/): the canonical trainer image does not
# exist, and the ci fixture's 8-vCPU/64Gi requests can never fit a cheap-run
# g4dn.xlarge. Image repo/tag come from the run's ECR (account-derived, same
# derivation as run.sh standins_up). -n team-ml: the Job carries no namespace
# and its Kueue queue label resolves the team-ml LocalQueue in the JOB's own
# namespace — applied bare it lands in default and is never admitted.
E2E_TRAINING_VALUES="${E2E_TRAINING_VALUES:-tests/e2e/stand-ins/training-values.yaml}"
training_render() {
  local repo="${E2E_STANDIN_IMAGE_REPO:-ghcr.io/nycterent/synorg/inference-stub}"
  helm template e2e-training charts/training-job -f "$E2E_TRAINING_VALUES" \
    --set image.repository="$repo" --set image.tag="${E2E_STANDIN_IMAGE_TAG:-0.1.0}"
}
training_submit() {
  training_render | k -n team-ml apply -f - >/dev/null
}
training_delete() {
  training_render | k -n team-ml delete -f - --ignore-not-found >/dev/null 2>&1 || true
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
  step "assert 1/8: lend — lendable node tainted lent + training borrows onto it"
  load_schedule_targets || { echo "FAIL: lend — cannot read live lending-schedule targets"; return 1; }
  # Quiescence gate: a previous run's restored schedule can leave the
  # controller mid-close-reclaim; driving a new window over leftover lent
  # nodes races the close path (observed: the just-lent node was close-path
  # deleted seconds after the lend assertion recorded it). Start clean.
  wait_until "lendable pool quiescent (no leftover lent node)" 900 no_lent_node \
    || { echo "FAIL: lend — leftover lent nodes did not clear; a prior run's reclaim is stuck"; return 1; }
  drive_schedule_now "$E2E_RAMP_MINUTES" || { echo "FAIL: lend — could not drive the schedule"; return 1; }
  training_submit || { echo "FAIL: lend — could not submit the training workload"; return 1; }
  wait_until "a $LENDABLE_POOL node carrying $LENT_TAINT_KEY" "$E2E_LEND_TIMEOUT" has_lent_node \
    || { echo "FAIL: lend — no node from pool '$LENDABLE_POOL' was tainted lent within ${E2E_LEND_TIMEOUT}s"; return 1; }
  echo "  lent nodes:"; lent_nodes | sed 's/^/    /'
  wait_until "a Running e2e-training pod on a lent node" "$E2E_LEND_TIMEOUT" training_pod_on_lent_node \
    || { echo "FAIL: lend — node lent but no training pod borrowed onto it within ${E2E_LEND_TIMEOUT}s"; return 1; }
  # The lendable-hold stand-in did its bootstrap job (a pool node exists and
  # is lent). Park it for the rest of the run: every wave-evicted hold pod
  # would otherwise re-provision a fresh lendable node that the still-open
  # window immediately re-lends — reclaim then chases its own tail past the
  # ramp deadline (observed live: reclaim finished 128s late). The training
  # job's own re-pending pods keep the pool occupied for the storm scenarios;
  # cleanup restores the hold.
  k -n platform-system scale deploy/lendable-hold --replicas=0 >/dev/null 2>&1 || true
  # Record the identity that must NOT survive the scrub (node-scrub.md Step 0).
  local node old_instance old_nodeclaim
  node="$(lent_nodes | head -1)"
  old_instance="$(k get node "$node" -o jsonpath='{.spec.providerID}')"
  old_nodeclaim="$(k get nodeclaim -o json \
    | jq -r --arg n "$node" '.items[] | select(.status.nodeName == $n) | .metadata.name')"
  { [ -n "$old_instance" ] && [ -n "$old_nodeclaim" ]; } \
    || { echo "FAIL: lend — cannot record old instance identity for node '$node' (needed by the scrub assertion)"; return 1; }
  printf '%s %s %s\n' "$node" "$old_instance" "$old_nodeclaim" > "$SCRUB_STATE"
  # Snapshot EVERY lendable-pool providerID at lend time (#20): the scrub
  # assertion passes only on a Ready pool node OUTSIDE this set — a genuinely
  # new EC2 instance, never a pre-existing sibling on a >=2-node fleet.
  k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -r '.items[].spec.providerID // empty' > "$POOL_ENTRY_IDS"
  [ -s "$POOL_ENTRY_IDS" ] \
    || { echo "FAIL: lend — could not snapshot lendable-pool providerIDs (needed by the scrub assertion)"; return 1; }
  echo "  pool entry snapshot: $(wc -l < "$POOL_ENTRY_IDS" | tr -d ' ') instance id(s) recorded"
  echo "PASS: lend — $node lent and borrowed onto (old identity recorded: ${old_instance##*/})"
}

# --- 2. reclaim ahead of ramp ------------------------------------------------
# Wave evidence (#19): the reclaim proof must be WAVE-driven, not close-path.
# drive_schedule_now places closesAt after the ramp deadline, and this helper
# reads the controller's own log lines (exact formats from
# controllers/lending/reconcile.sh; bounded by --since/--tail):
#   wave firing:        action=reclaim_wave wave=<name> lent_nodes=<n> reclaiming=<c>
#   wave NodeClaim del: action=nodeclaim_deleted node=<n> nodeclaim=<ncl> wave=<name> reason=NodeScrubStarted
# The close path logs `reason=window_close` instead of `wave=<name>`, and a
# due-but-empty wave logs msg="due but no lent nodes" WITHOUT a reclaiming=
# token — so the greps in the assertion match actual wave-driven action only.
controller_logs_since_drive() {
  local since=$(( $(date +%s) - E2E_DRIVE_EPOCH + 60 ))
  k -n lending logs deploy/lending-controller --since="${since}s" --tail=5000
}
assert_reclaim_ahead_of_ramp() {
  step "assert 2/8: reclaim-ahead-of-ramp — waves finish before the synthetic ramp needs capacity"
  [ -n "$LENDABLE_POOL" ] || { echo "FAIL: reclaim — schedule targets not loaded (did lend run?)"; return 1; }
  has_lent_node || { echo "FAIL: reclaim — nothing is lent, so there is nothing to reclaim (no vacuous pass)"; return 1; }
  # Scope the verdict to the nodes lent NOW (see none_of_set_lent): the waves
  # must return THIS lent capacity before the deadline; fresh borrows lent
  # after the final wave belong to the close.
  local lent_entry_set="$E2E_STATE_DIR/reclaim-entry-lent.txt"
  lent_nodes > "$lent_entry_set"
  local ramp_epoch=$(( $(date +%s) + E2E_RAMP_MINUTES * 60 ))
  loadgen_start "$E2E_RAMP_MINUTES" || { echo "FAIL: reclaim — could not start the synthetic inference ramp"; return 1; }
  # The driven schedule (assert_lend) placed the waves BEFORE the ramp deadline
  # and the window close AFTER it — within [now, deadline] only reclaimWaves
  # can clear lent taints, so the controller must reclaim wave-by-wave.
  wait_until "entry lent set reclaimed (waves complete)" $(( E2E_RAMP_MINUTES * 60 + 300 )) none_of_set_lent "$lent_entry_set" \
    || { echo "FAIL: reclaim — entry-set lent nodes remain after ramp + grace"; return 1; }
  local done_epoch; done_epoch="$(date +%s)"
  if [ "$done_epoch" -ge "$ramp_epoch" ]; then
    echo "FAIL: reclaim finished $(( done_epoch - ramp_epoch ))s AFTER the ramp deadline — the render path would have queued"
    return 1
  fi
  # Positive wave evidence (#19): the controller must have LOGGED the waves
  # doing the work. Unreachable controller logs are a hard FAIL on EKS — a run
  # without its actuator's evidence has no verdict, never a skip.
  local logs waves_fired wave_deletes
  if ! logs="$(controller_logs_since_drive)"; then
    echo "FAIL: reclaim — cannot read controller logs (kubectl logs deploy/lending-controller -n lending) — wave evidence unavailable, no verdict"
    return 1
  fi
  waves_fired="$(grep -c 'action=reclaim_wave .*reclaiming=' <<<"$logs" || true)"
  if [ "${waves_fired:-0}" -lt 1 ]; then
    echo "FAIL: reclaim — taints cleared before the deadline but the controller logged NO firing wave (action=reclaim_wave ... reclaiming=) since the schedule was driven — the staged waves did not do the reclaiming"
    return 1
  fi
  # EKS path: the waves must have crossed the Karpenter scrub boundary. The
  # taints were observed clear before the deadline, which precedes closesAt
  # (drive_schedule_now ordering invariant), so every wave= deletion seen here
  # happened before the window closed.
  wave_deletes="$(grep -c 'action=nodeclaim_deleted .*wave=' <<<"$logs" || true)"
  if [ "${wave_deletes:-0}" -lt 1 ]; then
    echo "FAIL: reclaim — no wave-driven NodeClaim deletion (action=nodeclaim_deleted ... wave=) in controller logs — reclaim never crossed the Karpenter scrub boundary"
    return 1
  fi
  echo "  wave evidence: $waves_fired wave firing(s), $wave_deletes wave-driven NodeClaim deletion(s) before closesAt"
  echo "PASS: reclaim-ahead-of-ramp — completed $(( ramp_epoch - done_epoch ))s before the ramp deadline, wave-driven"
}

# --- 3. scrub: new instance-id -----------------------------------------------
nodeclaim_gone() { ! k get nodeclaim "$1" >/dev/null 2>&1; }
# fresh_pool_node — PREDICATE (#20): some Ready pool node carries a providerID
# OUTSIDE the lend-time entry snapshot ($POOL_ENTRY_IDS) — a genuinely NEW EC2
# instance. A pre-existing sibling (any fleet >= 2) is in the snapshot and can
# never satisfy this.
fresh_pool_node() {
  local entry; entry="$(cat "$POOL_ENTRY_IDS")" || return 1
  k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -e --arg entry "$entry" '
        ($entry | split("\n") | map(select(length > 0))) as $set
        | [.items[]
           | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))
           | select(.spec.providerID != null)
           | select(.spec.providerID as $p | ($set | index($p)) == null)
          ] | length > 0' >/dev/null
}
assert_scrub_new_instance() {
  step "assert 4/8: scrub — reclaimed nodeclaim deleted, replacement is a genuinely NEW EC2 instance"
  [ -s "$SCRUB_STATE" ] || { echo "FAIL: scrub — no recorded old identity (lend assertion must pass first)"; return 1; }
  [ -s "$POOL_ENTRY_IDS" ] || { echo "FAIL: scrub — no lend-time pool snapshot (lend assertion must pass first)"; return 1; }
  local node old_instance old_nodeclaim entry_ids entry_size
  read -r node old_instance old_nodeclaim < "$SCRUB_STATE"
  entry_ids="$(cat "$POOL_ENTRY_IDS")"
  entry_size="$(wc -l < "$POOL_ENTRY_IDS" | tr -d ' ')"
  wait_until "nodeclaim $old_nodeclaim deleted (instance terminated)" "$E2E_SCRUB_TIMEOUT" \
    nodeclaim_gone "$old_nodeclaim" \
    || { echo "FAIL: scrub — nodeclaim '$old_nodeclaim' still exists; the reclaimed node was never scrubbed"; return 1; }
  wait_until "a Ready $LENDABLE_POOL node outside the lend-time entry set" "$E2E_SCRUB_TIMEOUT" fresh_pool_node \
    || { echo "FAIL: scrub — every Ready pool node's instance-id is inside the lend-time entry set ($entry_size id(s)); no genuinely new EC2 instance within ${E2E_SCRUB_TIMEOUT}s (a pre-existing sibling does not count)"; return 1; }
  local new_instance
  new_instance="$(k get nodes -l "karpenter.sh/nodepool=$LENDABLE_POOL" -o json \
    | jq -r --arg entry "$entry_ids" '
        ($entry | split("\n") | map(select(length > 0))) as $set
        | [.items[] | .spec.providerID | select(. != null) | . as $p | select(($set | index($p)) == null)][0] // empty')"
  # Membership already implies new != old (old is in the entry set), but keep
  # the explicit guard on the reclaimed node: an equal instance-id means VRAM
  # was never reset — node-scrub.md abort case.
  if [ -z "$new_instance" ] || [ "$new_instance" = "$old_instance" ]; then
    echo "FAIL: scrub — replacement instance-id equals the old one (VRAM not reset; node-scrub.md abort)"
    return 1
  fi
  echo "  entry set:    $entry_size lend-time instance id(s)"
  echo "  old instance: ${old_instance##*/}  (node $node, nodeclaim $old_nodeclaim)"
  echo "  new instance: ${new_instance##*/}  (outside the lend-time set)"
  echo "PASS: scrub — instance discarded and recovered on a genuinely new instance (outside the entry set, old != new)"
}

# --- 4. rejoin under the render-start p95 gate -------------------------------
assert_rejoin_under_p95_gate() {
  step "assert 5/8: rejoin — render_start p95 holds the gate through reclaim + rejoin"
  local target p95
  target="$(yq -r '.data["scenarios.yaml"]' rehearsal/scenarios.yaml \
    | yq -r '.parameters.renderStartP95TargetSeconds')"
  [ -n "$target" ] && [ "$target" != "null" ] \
    || { echo "FAIL: rejoin — no renderStartP95TargetSeconds in rehearsal/scenarios.yaml"; return 1; }
  # Same series as runbooks/game-day.md Step 5 — the reclaim-window-scoped
  # p95. WORST value since the schedule was driven, not an instant read: the
  # gated series only has samples while the flag is 1, and by the time this
  # assertion runs (after the scrub) the window is closed — an instant query
  # would go stale-empty even on a healthy run. "Held the gate THROUGH reclaim
  # + rejoin" is exactly max-over-the-window.
  local range=$(( $(date +%s) - E2E_DRIVE_EPOCH + 300 ))
  p95="$(Q "max_over_time(render_start_seconds:p95:reclaim_window[${range}s])")"
  if [ -z "$p95" ]; then
    echo "FAIL: rejoin — render_start_seconds:p95:reclaim_window returned no samples over the driven window (an unmeasured run has no verdict, game-day.md)"
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
    # Cheap-run override (run.sh sets it): checkpoints land on node-local disk
    # (stand-ins/checkpoint-pv.yaml), so the shared-store throughput FLOOR is
    # retuned, LOUDLY — the gate still proves writes happen and are measured.
    if [ "$param" = "sharedStoreMinThroughputMBps" ] && [ -n "${E2E_SHARED_STORE_MIN_MBPS:-}" ]; then
      echo "  gate OVERRIDE: $param $threshold -> $E2E_SHARED_STORE_MIN_MBPS (node-local checkpoint stand-in, not the shared store)"
      threshold="$E2E_SHARED_STORE_MIN_MBPS"
    fi
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
# --- borrower drain (ADR 0008) -----------------------------------------------
# The training Workload submitted by assert_lend borrows through the team-ml
# LocalQueue. Once the reclaim phase is in force (first wave fired — which
# assert_reclaim just proved), the controller must have deactivated it and
# stamped the drained annotation. Workload-level evidence, not pod-level:
# reclaim already killed the pods either way; drain is what stops them
# re-pending into the tail-chase.
borrowing_workloads_json() { k -n team-ml get workloads.kueue.x-k8s.io -o json; }

all_borrowers_drained() {
  borrowing_workloads_json | jq -e '
    [.items[] | select(.spec.queueName == "team-ml")] as $b
    | ($b | length) > 0 and ([$b[] | select(.spec.active == false and .metadata.annotations["lending.synorg.io/drained"] == "true")] | length) == ($b | length)' >/dev/null
}

no_borrowers_marked_drained() {
  borrowing_workloads_json | jq -e '
    [.items[] | select(.metadata.annotations["lending.synorg.io/drained"] == "true")] | length == 0' >/dev/null
}

assert_borrower_drain() {
  step "assert 3/8: borrower drain — reclaim phase deactivates every borrowing Workload"
  local n
  n="$(borrowing_workloads_json | jq '[.items[] | select(.spec.queueName == "team-ml")] | length')"
  [ "${n:-0}" -ge 1 ] || { echo "FAIL: borrower-drain — no borrowing Workloads exist, nothing to drain (no vacuous pass)"; return 1; }
  # Two controller ticks + margin: drain is level-triggered, not instant.
  wait_until "borrowing Workloads deactivated + drained-annotated" 180 all_borrowers_drained \
    || { echo "FAIL: borrower-drain — borrowing Workloads still active (or unmarked) inside the reclaim phase"; return 1; }
  local logs
  if ! logs="$(controller_logs_since_drive)"; then
    echo "FAIL: borrower-drain — cannot read controller logs — drain evidence unavailable, no verdict"
    return 1
  fi
  grep -q 'action=borrower_drained' <<<"$logs" \
    || { echo "FAIL: borrower-drain — no action=borrower_drained in controller logs (state may predate the phase)"; return 1; }
  echo "PASS: borrower drain — $n borrowing Workload(s) deactivated and marked during the reclaim phase"
}

# --- borrower reactivation (ADR 0008) ----------------------------------------
# After the driven window's close the phase is over: exactly the Workloads the
# controller marked must come back (annotation removed, spec.active no longer
# false). They then pend against the shrunk quota — re-admission is Kueue's
# business, not this gate's.
assert_borrower_reactivation() {
  step "assert 7/8: borrower reactivation — phase exit unmarks and reactivates drained Workloads"
  # The last storm scenario drove close at +$E2E_CLOSE_MINUTES from its drive
  # epoch; wait out the remainder plus two ticks.
  local deadline=$(( E2E_DRIVE_EPOCH + E2E_CLOSE_MINUTES * 60 + 180 )) now
  now="$(date +%s)"
  local budget=$(( deadline - now )); [ "$budget" -gt 60 ] || budget=180
  wait_until "drained annotations cleared after window close" "$budget" no_borrowers_marked_drained \
    || { echo "FAIL: borrower-reactivation — Workloads still marked drained after the window closed (stuck drain)"; return 1; }
  local logs
  if ! logs="$(controller_logs_since_drive)"; then
    echo "FAIL: borrower-reactivation — cannot read controller logs — reactivation evidence unavailable, no verdict"
    return 1
  fi
  grep -q 'action=borrower_reactivated' <<<"$logs" \
    || { echo "FAIL: borrower-reactivation — no action=borrower_reactivated in controller logs"; return 1; }
  echo "PASS: borrower reactivation — drained set emptied and reactivation logged after phase exit"
}

assert_game_day_storm() {
  step "assert 6/8: game-day storm — scenarios from rehearsal/scenarios.yaml pass their gates"
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
  step "assert 8/8: ledger — zero net capacity release (capacity-carve.md invariant)"
  # Baseline is the TEST-START snapshot (taken in e2e_assert_all), not the
  # run-entry one: --up legitimately creates the run-owned cheap ODCR after
  # the run-entry snapshot, so comparing against run-entry would flag every
  # kept-stack --test as drift. This assertion's scope is "the game-day
  # physics released/created no capacity"; the run-level fresh==fresh
  # invariant stays with run.sh's ledger_assert_unchanged at --down.
  [ -f "$LEDGER_TEST_ENTRY_FILE" ] || { echo "FAIL: ledger — no test-start snapshot to compare against"; return 1; }
  local now_file="$E2E_STATE_DIR/ledger-test.txt"
  ledger_read > "$now_file" || { echo "FAIL: ledger — cannot read reservation state"; return 1; }
  if ! diff -u "$LEDGER_TEST_ENTRY_FILE" "$now_file"; then
    echo "FAIL: ledger — reservation totals/held drifted during the test (capacity released or lost)"
    return 1
  fi
  echo "PASS: ledger — reservation totals/held identical to the test-start snapshot"
}

# --- Cleanup + trap chaining -------------------------------------------------
# A kill (INT/TERM) or hard exit mid---test must not leave the loadgen, the
# training workload, or a driven schedule live: ArgoCD selfHeal eventually
# reverts the schedule ConfigMap, but loadgen and the training workload are
# NOT ArgoCD-managed — only this cleanup removes them. The cleanup runs
# exactly once (guard variable), whether reached normally or via a trap.
#
# Trap chaining: this file is SOURCED by tests/e2e/run.sh, whose full cycle
# installs its own on_exit trap (teardown). The previous handlers are captured
# BEFORE installing ours, chained after the cleanup, and restored when the
# assertion run completes — run.sh's teardown trap always still fires.
E2E_CLEANUP_DONE=0
E2E_PREV_TRAP_EXIT=""
E2E_PREV_TRAP_INT=""
E2E_PREV_TRAP_TERM=""

e2e_cleanup() {
  [ "$E2E_CLEANUP_DONE" = 1 ] && return 0
  E2E_CLEANUP_DONE=1
  step "assertions cleanup (loadgen, training workload, schedule, port-forward)"
  loadgen_stop
  training_delete
  # Restore the lendable-hold bootstrap (parked after the lend assertion) so
  # the kept stack is ready for the next --test without re-running --up.
  k -n platform-system scale deploy/lendable-hold --replicas=1 >/dev/null 2>&1 || true
  restore_schedule || echo "  WARNING: could not restore the original schedule — restore it manually from $SCHEDULE_ORIG" >&2
  prom_stop
  return 0
}

# e2e__store_trap '--' BODY SIGNAL — sink for re-evaluating one `trap -p` line
# (each line is valid shell: trap -- '<body>' SIG); records BODY per signal.
# bash prints signal names with the SIG prefix (SIGINT/SIGTERM) — match both.
e2e__store_trap() {
  case "$3" in
    EXIT)         E2E_PREV_TRAP_EXIT="$2" ;;
    INT|SIGINT)   E2E_PREV_TRAP_INT="$2" ;;
    TERM|SIGTERM) E2E_PREV_TRAP_TERM="$2" ;;
  esac
}

# e2e_install_cleanup_trap — capture the current EXIT/INT/TERM handlers, then
# install combined handlers: cleanup first, previous handler after. `trap -p`
# is written to a FILE (a redirection, not a command substitution) because a
# subshell would report its own reset traps, not run.sh's. Single-line handler
# bodies only — which run.sh's `on_exit` is.
e2e_install_cleanup_trap() {
  E2E_CLEANUP_DONE=0
  E2E_PREV_TRAP_EXIT=""; E2E_PREV_TRAP_INT=""; E2E_PREV_TRAP_TERM=""
  local tf="$E2E_STATE_DIR/.prev-traps" line
  trap -p EXIT INT TERM > "$tf"
  while IFS= read -r line; do
    eval "e2e__store_trap ${line#trap }"
  done < "$tf"
  rm -f "$tf"
  # $? is captured FIRST and re-armed with `(exit ...)` so a chained handler
  # that reads $? (run.sh on_exit does) sees the dying rc, not the cleanup's.
  # `set +e` before the re-arm: errexit is live inside trap handlers, and a
  # nonzero (exit rc) would otherwise abort the handler BEFORE the chained
  # teardown runs (proven offline). The handler only runs on a dying/signalled
  # script, so dropping errexit there changes nothing else.
  # Intentional early expansion of the captured bodies (shellcheck SC2064);
  # e2e_rc is assigned inside the handler string itself (SC2154).
  # shellcheck disable=SC2064,SC2154
  trap "e2e_rc=\$?; e2e_cleanup; set +e; (exit \"\$e2e_rc\"); ${E2E_PREV_TRAP_EXIT}" EXIT
  if [ -n "$E2E_PREV_TRAP_INT" ]; then
    # shellcheck disable=SC2064
    trap "e2e_rc=\$?; e2e_cleanup; set +e; (exit \"\$e2e_rc\"); ${E2E_PREV_TRAP_INT}" INT
  else
    # No previous INT handler: clean up, then re-raise so the default
    # die-on-SIGINT semantics (and run.sh's EXIT-less phases) are preserved.
    trap 'e2e_cleanup; trap - INT; kill -INT $$' INT
  fi
  if [ -n "$E2E_PREV_TRAP_TERM" ]; then
    # shellcheck disable=SC2064
    trap "e2e_rc=\$?; e2e_cleanup; set +e; (exit \"\$e2e_rc\"); ${E2E_PREV_TRAP_TERM}" TERM
  else
    trap 'e2e_cleanup; trap - TERM; kill -TERM $$' TERM
  fi
}

# e2e_restore_traps — put back exactly what was captured (or clear). Early
# expansion is the point: restore the ORIGINAL bodies verbatim (SC2064).
e2e_restore_traps() {
  # shellcheck disable=SC2064
  if [ -n "$E2E_PREV_TRAP_EXIT" ]; then trap "$E2E_PREV_TRAP_EXIT" EXIT; else trap - EXIT; fi
  # shellcheck disable=SC2064
  if [ -n "$E2E_PREV_TRAP_INT" ]; then trap "$E2E_PREV_TRAP_INT" INT; else trap - INT; fi
  # shellcheck disable=SC2064
  if [ -n "$E2E_PREV_TRAP_TERM" ]; then trap "$E2E_PREV_TRAP_TERM" TERM; else trap - TERM; fi
}

# --- Runner ------------------------------------------------------------------
# e2e_assert_all — run every assertion in order, keep going after a failure so
# one run reports the full physics picture; rc!=0 if any failed. Cleanup
# (loadgen off, training deleted, schedule restored, port-forward closed)
# always runs — normal completion, assertion failure, or a mid-run kill.
e2e_assert_all() {
  local failed=0 a
  e2e_install_cleanup_trap
  # Test-start ledger baseline for assert 6 (see its comment): captured before
  # any assertion touches the cluster. An unreadable ledger fails HERE — a run
  # that can't prove its capacity baseline has no verdict.
  # A prior run's saved original must not leak into this one: the first
  # drive_schedule_now of THIS run owns the save.
  rm -f "$SCHEDULE_ORIG"
  LEDGER_TEST_ENTRY_FILE="$E2E_STATE_DIR/ledger-test-entry.txt"
  if ! ledger_read > "$LEDGER_TEST_ENTRY_FILE"; then
    echo "FAIL: ledger — cannot read reservation state at test start (no baseline, no verdict)"
    e2e_restore_traps
    return 1
  fi
  if ! prom_start; then
    echo "FAIL: evidence plane unreachable — an unmeasured run has no verdict (game-day.md abort)"
    e2e_cleanup          # includes prom_stop — no leaked port-forward
    e2e_restore_traps
    return 1
  fi
  for a in assert_lend assert_reclaim_ahead_of_ramp assert_borrower_drain \
           assert_scrub_new_instance assert_rejoin_under_p95_gate \
           assert_game_day_storm assert_borrower_reactivation \
           assert_ledger_zero_net_release; do
    "$a" || failed=$(( failed + 1 ))
  done
  e2e_cleanup
  e2e_restore_traps
  echo
  if [ "$failed" -gt 0 ]; then
    echo "ASSERTIONS: $failed of 8 FAILED"
    return 1
  fi
  echo "ASSERTIONS: 8 of 8 PASSED"
}
