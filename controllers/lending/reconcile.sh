#!/usr/bin/env bash
# reconcile.sh — U4 thin lending controller (v0). A kubectl-driven loop that
# actuates the git-controlled lending schedule (clusters/pilot/lending/
# schedule.yaml, mounted as a ConfigMap): per tick it
#   1. reconciles the lent taint on lendable-pool Node objects to the current
#      window state,
#   2. patches the training ClusterQueue borrowingLimit to the curve value for
#      the current time (gpuLimitPct x current lendable GPU capacity),
#   3. on a due reclaim wave: cordon+drain the selected lent nodes and delete
#      their NodeClaims (EKS); on a cluster without Karpenter (kind) it LOGS
#      the intended action only — the ClusterRole has no nodes:delete and kind
#      has no NodeClaims, by design.
#
# WRITE SURFACE (drift trap, plan-001 U8): Node objects and the training
# ClusterQueue only. NEVER NodePool templates — Karpenter drift-detects a
# template change and replaces the whole pool at every window transition.
#
# Region-local by construction: everything here talks to the local API server
# via the mounted ServiceAccount; there is no hub/ArgoCD dependency at tick
# time. A malformed schedule logs schedule_invalid and skips the tick — it
# never crash-loops the actuator.
#
# RBAC-CHECK CONTRACT (test.sh parses this file): every kubectl call goes
# through the single-line `kc <subcommand> <resource> ...` wrapper below, with
# the resource token immediately after the subcommand. Do not call kubectl
# directly and do not split a kc invocation across lines — test.sh maps each
# invocation to RBAC verbs and fails closed on anything it cannot parse.
#
# Offline mode: `reconcile.sh --print-borrow-path` reads ClusterQueue JSON on
# stdin and prints the JSON-pointer path of its nvidia.com/gpu borrowingLimit
# (empty when absent), then exits 0 — no cluster access. test.sh uses it so
# its path lookup and the controller's are one implementation.
#
# Config (env):
#   SCHEDULE_FILE       schedule to actuate      (default /etc/lending/schedule.yaml)
#   TICK_SECONDS        loop period              (default 60)
#   KUBECTL_CACHE_DIR   writable kubectl cache — the container runs
#                       readOnlyRootFilesystem, so this points into the
#                       emptyDir mounted at /tmp (default /tmp/kubectl-cache)
#   EVENT_NAMESPACE     namespace for emitted Events (default lending)
#   EMIT_EVENTS         emit Kubernetes Events per action (default true)
#   WAVE_FIRE_WINDOW_SECONDS  how long after startsAt a wave stays due (default 300)
#   MAX_TICKS           stop after N ticks; 0 = run forever (test hook)
set -euo pipefail

SCHEDULE_FILE="${SCHEDULE_FILE:-/etc/lending/schedule.yaml}"
TICK_SECONDS="${TICK_SECONDS:-60}"
KUBECTL_CACHE_DIR="${KUBECTL_CACHE_DIR:-/tmp/kubectl-cache}"
EVENT_NAMESPACE="${EVENT_NAMESPACE:-lending}"
EMIT_EVENTS="${EMIT_EVENTS:-true}"
WAVE_FIRE_WINDOW_SECONDS="${WAVE_FIRE_WINDOW_SECONDS:-300}"
MAX_TICKS="${MAX_TICKS:-0}"

# kc — the single kubectl entrypoint (see RBAC-CHECK CONTRACT above).
kc() { kubectl --cache-dir="$KUBECTL_CACHE_DIR" "$@"; }

# log LEVEL KEY=VALUE... — structured single-line logs (the evidence plane and
# the kind-path reclaim assertions grep these).
log() {
  local level="$1"; shift
  echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) level=$level component=lending-controller $*"
}

# emit_event REASON KIND NAME MESSAGE — emit-events contract (plan-001 U8):
# every state transition lands as a Kubernetes Event on the Node (or, for
# quota changes, the ClusterQueue) so U9 evidence never scrapes logs.
emit_event() {
  local reason="$1" kind="$2" name="$3" message="$4" api="v1" ts
  [ "$EMIT_EVENTS" = "true" ] || return 0
  [ "$kind" = "ClusterQueue" ] && api="kueue.x-k8s.io/v1beta1"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kc create -f - >/dev/null <<EOF || log warn action=emit_event reason="$reason" msg="event create failed (non-fatal)"
apiVersion: v1
kind: Event
metadata:
  generateName: lending-controller-
  namespace: $EVENT_NAMESPACE
type: Normal
reason: $reason
message: "$message"
involvedObject:
  apiVersion: $api
  kind: $kind
  name: $name
reportingComponent: lending-controller
reportingInstance: ${HOSTNAME:-lending-controller}
source:
  component: lending-controller
firstTimestamp: "$ts"
lastTimestamp: "$ts"
count: 1
EOF
}

# hm_to_min "HH:MM" -> minutes since local midnight.
hm_to_min() {
  local h m
  IFS=: read -r h m <<<"$1"
  echo $(( 10#$h * 60 + 10#$m ))
}

# minutes_since NOW_MIN AT_MIN -> minutes since AT last occurred (daily wrap).
minutes_since() { echo $(( ($1 - $2 + 1440) % 1440 )); }

# validate_schedule — parse + schema-gate the schedule. Any failure logs
# schedule_invalid with the reason and returns 1 (tick is skipped, no crash).
validate_schedule() {
  local sv field
  if ! yq -e '.' "$SCHEDULE_FILE" >/dev/null 2>&1; then
    log error action=schedule_invalid file="$SCHEDULE_FILE" msg="not parseable as YAML"
    return 1
  fi
  sv="$(yq -r '.schemaVersion // ""' "$SCHEDULE_FILE")"
  if [ "$sv" != "1" ]; then
    log error action=schedule_invalid file="$SCHEDULE_FILE" msg="unsupported schemaVersion '$sv' (want 1) — refusing to actuate"
    return 1
  fi
  for field in timezone targets.lendablePool targets.lentTaint targets.trainingQueue windows borrowingLimitCurve; do
    if [ "$(yq -r ".$field // \"\"" "$SCHEDULE_FILE")" = "" ]; then
      log error action=schedule_invalid file="$SCHEDULE_FILE" msg="missing required field $field"
      return 1
    fi
  done
  return 0
}

# window_open TZ — 0 (open) when any window covers local now, handling windows
# that wrap midnight (open 22:00, close 06:30: the early-morning tail belongs
# to the previous day's `days` entry).
window_open() {
  local tz="$1" now_min day prev_day n i opens closes days o c
  now_min="$(hm_to_min "$(TZ="$tz" date +%H:%M)")"
  day="$(TZ="$tz" date +%a)"
  local dow; dow="$(TZ="$tz" date +%w)"                    # 0=Sun
  local names=(Sun Mon Tue Wed Thu Fri Sat)
  prev_day="${names[$(( (dow + 6) % 7 ))]}"
  n="$(yq -r '.windows | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    opens="$(yq -r ".windows[$i].opensAt" "$SCHEDULE_FILE")"
    closes="$(yq -r ".windows[$i].closesAt" "$SCHEDULE_FILE")"
    days="$(yq -r ".windows[$i].days | join(\",\")" "$SCHEDULE_FILE")"
    o="$(hm_to_min "$opens")"; c="$(hm_to_min "$closes")"
    if [ "$o" -le "$c" ]; then
      case ",$days," in *",$day,"*)
        [ "$now_min" -ge "$o" ] && [ "$now_min" -lt "$c" ] && return 0 ;; esac
    else
      case ",$days," in *",$day,"*)
        [ "$now_min" -ge "$o" ] && return 0 ;; esac
      case ",$days," in *",$prev_day,"*)
        [ "$now_min" -lt "$c" ] && return 0 ;; esac
    fi
  done
  return 1
}

# reconcile_taints OPEN POOL TAINT — converge lent taint on lendable Nodes to
# the window state; emit NodeLent / NodeReturnedToProd / LendWindowOpened only
# on actual transitions (idempotent per tick).
reconcile_taints() {
  local open="$1" pool="$2" taint="$3"
  local tkey tval teff nodes_json node has any_lent=0
  tkey="${taint%%=*}"; tval="${taint#*=}"; tval="${tval%%:*}"; teff="${taint##*:}"
  nodes_json="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json)"
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    has="$(echo "$nodes_json" | jq -r --arg n "$node" --arg k "$tkey" \
      '.items[] | select(.metadata.name == $n) | .spec.taints // [] | any(.key == $k)')"
    if [ "$open" = "1" ] && [ "$has" != "true" ]; then
      kc taint node "$node" "$tkey=$tval:$teff" --overwrite >/dev/null
      log info action=taint_added node="$node" taint="$taint" reason=NodeLent
      emit_event NodeLent Node "$node" "lending window open: taint $taint applied"
      any_lent=1
    elif [ "$open" = "0" ] && [ "$has" = "true" ]; then
      kc taint node "$node" "$tkey:$teff-" >/dev/null
      log info action=taint_removed node="$node" taint="$taint" reason=NodeReturnedToProd
      emit_event NodeReturnedToProd Node "$node" "lending window closed: taint $taint removed"
    fi
  done < <(echo "$nodes_json" | jq -r '.items[].metadata.name')
  if [ "$any_lent" = "1" ]; then
    emit_event LendWindowOpened Node "$pool" "lending window opened for pool $pool"
  fi
}

# borrow_limit_path — read ClusterQueue JSON on stdin, print the JSON-pointer
# path of its nvidia.com/gpu borrowingLimit ("" when absent). Exposed offline
# as `reconcile.sh --print-borrow-path` (test.sh shares this implementation).
borrow_limit_path() {
  jq -r 'first(.spec.resourceGroups // [] | to_entries[] as $g | $g.value.flavors // [] | to_entries[] as $f | $f.value.resources // [] | to_entries[] as $r | select($r.value.name == "nvidia.com/gpu") | "/spec/resourceGroups/\($g.key)/flavors/\($f.key)/resources/\($r.key)/borrowingLimit") // ""'
}

# reconcile_borrow_limit TZ POOL QUEUE — patch the training ClusterQueue
# borrowingLimit to gpuLimitPct(now) x current lendable nvidia.com/gpu
# capacity. The active curve entry is the most recently passed `at` (daily
# recurrence). Patch only on change; emit BorrowLimitPatched on the queue.
reconcile_borrow_limit() {
  local tz="$1" pool="$2" queue="$3"
  local now_min n i at pct best_delta=1441 best_pct="" delta
  now_min="$(hm_to_min "$(TZ="$tz" date +%H:%M)")"
  n="$(yq -r '.borrowingLimitCurve | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    at="$(yq -r ".borrowingLimitCurve[$i].at" "$SCHEDULE_FILE")"
    pct="$(yq -r ".borrowingLimitCurve[$i].gpuLimitPct" "$SCHEDULE_FILE")"
    delta="$(minutes_since "$now_min" "$(hm_to_min "$at")")"
    if [ "$delta" -lt "$best_delta" ]; then best_delta="$delta"; best_pct="$pct"; fi
  done
  [ -n "$best_pct" ] || { log warn action=borrow_limit msg="empty curve, skipping"; return 0; }

  local capacity limit cq_json path current
  capacity="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json \
    | jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add // 0')"
  limit="$(awk -v c="$capacity" -v p="$best_pct" 'BEGIN { printf "%d", (c * p) / 100 }')"

  if ! cq_json="$(kc get clusterqueue "$queue" -o json 2>/dev/null)"; then
    log warn action=borrow_limit queue="$queue" msg="ClusterQueue not found, skipping"
    return 0
  fi
  path="$(echo "$cq_json" | borrow_limit_path)"
  if [ -z "$path" ]; then
    log warn action=borrow_limit queue="$queue" msg="no nvidia.com/gpu resource in queue, skipping"
    return 0
  fi
  current="$(echo "$cq_json" | jq -r --arg p "$path" 'getpath($p | ltrimstr("/") | split("/") | map(if test("^[0-9]+$") then tonumber else . end))')"
  if [ "$current" != "$limit" ]; then
    kc patch clusterqueue "$queue" --type=json -p "[{\"op\": \"replace\", \"path\": \"$path\", \"value\": $limit}]" >/dev/null
    log info action=borrow_limit_patched queue="$queue" pct="$best_pct" capacity="$capacity" from="$current" to="$limit" reason=BorrowLimitPatched
    emit_event BorrowLimitPatched ClusterQueue "$queue" "borrowingLimit $current -> $limit (${best_pct}% of $capacity lendable GPUs)"
  fi
}

# reconcile_waves TZ POOL TAINT — fire any due reclaim wave. EKS: cordon,
# drain (eviction API, drainGraceSeconds), delete the NodeClaim so Karpenter
# terminates the instance (scrub boundary). kind: no Karpenter API — log the
# intended action only (reclaim_intent) and do not error.
reconcile_waves() {
  local tz="$1" pool="$2" taint="$3"
  local tkey="${taint%%=*}"
  local now_min n i starts fraction grace delta lent count karpenter=0
  now_min="$(hm_to_min "$(TZ="$tz" date +%H:%M)")"
  n="$(yq -r '.reclaimWaves // [] | length' "$SCHEDULE_FILE")"
  [ "$n" -gt 0 ] || return 0
  if kc api-versions | grep -q '^karpenter.sh/'; then karpenter=1; fi
  for (( i=0; i<n; i++ )); do
    starts="$(yq -r ".reclaimWaves[$i].startsAt" "$SCHEDULE_FILE")"
    fraction="$(yq -r ".reclaimWaves[$i].reclaimFraction" "$SCHEDULE_FILE")"
    grace="$(yq -r ".reclaimWaves[$i].drainGraceSeconds // 120" "$SCHEDULE_FILE")"
    delta="$(minutes_since "$now_min" "$(hm_to_min "$starts")")"
    [ $(( delta * 60 )) -lt "$WAVE_FIRE_WINDOW_SECONDS" ] || continue
    # currently-lent nodes = lendable-pool nodes carrying the lent taint
    lent="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json \
      | jq -r --arg k "$tkey" '.items[] | select(.spec.taints // [] | any(.key == $k)) | .metadata.name')"
    if [ -z "$lent" ]; then
      log info action=reclaim_wave wave="$(yq -r ".reclaimWaves[$i].name" "$SCHEDULE_FILE")" msg="due but no lent nodes"
      continue
    fi
    count="$(awk -v n="$(echo "$lent" | wc -l | tr -d ' ')" -v f="$fraction" \
      'BEGIN { c = n * f; printf "%d", (c == int(c)) ? c : int(c) + 1 }')"
    local wave_name; wave_name="$(yq -r ".reclaimWaves[$i].name" "$SCHEDULE_FILE")"
    log info action=reclaim_wave wave="$wave_name" lent_nodes="$(echo "$lent" | wc -l | tr -d ' ')" reclaiming="$count"
    # One cluster-wide NodeClaim fetch per wave (not per node): each node maps
    # to a distinct claim, so looking a node's claim up from this cache stays
    # correct even as the loop below deletes claims one by one.
    local node ncl nodeclaims_json='{"items":[]}'
    if [ "$karpenter" = "1" ]; then
      nodeclaims_json="$(kc get nodeclaims -o json)"
    fi
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      if [ "$karpenter" = "1" ]; then
        emit_event ReclaimWaveStarted Node "$node" "reclaim wave $wave_name: cordon+drain+nodeclaim delete"
        kc cordon "$node" >/dev/null
        emit_event NodeDraining Node "$node" "draining with ${grace}s grace (wave $wave_name)"
        kc drain "$node" --ignore-daemonsets --delete-emptydir-data --grace-period="$grace" --timeout="$(( grace * 3 ))s" >/dev/null \
          || log warn action=drain_incomplete node="$node" msg="drain did not finish cleanly, proceeding to nodeclaim delete"
        ncl="$(echo "$nodeclaims_json" | jq -r --arg n "$node" '.items[] | select(.status.nodeName == $n) | .metadata.name' | head -1)"
        if [ -n "$ncl" ]; then
          kc delete nodeclaim "$ncl" --wait=false >/dev/null
          log info action=nodeclaim_deleted node="$node" nodeclaim="$ncl" wave="$wave_name" reason=NodeScrubStarted
          emit_event NodeScrubStarted Node "$node" "nodeclaim $ncl deleted; Karpenter terminates the instance (scrub boundary)"
        else
          log warn action=reclaim node="$node" msg="no NodeClaim found for node, skipping delete"
        fi
      else
        # kind path: no Karpenter and the ClusterRole grants no nodes:delete —
        # a real deletion is impossible by construction, so log the intent.
        log info action=reclaim_intent node="$node" wave="$wave_name" msg="would cordon+drain node and delete its nodeclaim (no Karpenter on this cluster; log-only)"
      fi
    done < <(echo "$lent" | head -n "$count")
  done
}

# tick — one reconcile pass. Malformed schedule -> log + return (skip).
tick() {
  validate_schedule || return 0
  local tz pool taint queue open=0
  tz="$(yq -r '.timezone' "$SCHEDULE_FILE")"
  pool="$(yq -r '.targets.lendablePool' "$SCHEDULE_FILE")"
  taint="$(yq -r '.targets.lentTaint' "$SCHEDULE_FILE")"
  queue="$(yq -r '.targets.trainingQueue' "$SCHEDULE_FILE")"
  if window_open "$tz"; then open=1; fi
  log info action=tick window_open="$open" pool="$pool" queue="$queue"
  reconcile_taints "$open" "$pool" "$taint" || log warn action=tick msg="taint reconcile failed, continuing"
  reconcile_borrow_limit "$tz" "$pool" "$queue" || log warn action=tick msg="borrow-limit reconcile failed, continuing"
  reconcile_waves "$tz" "$pool" "$taint" || log warn action=tick msg="wave reconcile failed, continuing"
}

main() {
  local ticks=0
  command -v yq >/dev/null 2>&1 || { log error msg="yq not installed"; exit 1; }
  command -v jq >/dev/null 2>&1 || { log error msg="jq not installed"; exit 1; }
  mkdir -p "$KUBECTL_CACHE_DIR"
  trap 'log info msg="terminating"; exit 0' TERM INT
  log info msg="starting" schedule="$SCHEDULE_FILE" tick_seconds="$TICK_SECONDS"
  while :; do
    tick || log error action=tick msg="tick failed, continuing"
    ticks=$(( ticks + 1 ))
    if [ "$MAX_TICKS" -gt 0 ] && [ "$ticks" -ge "$MAX_TICKS" ]; then break; fi
    sleep "$TICK_SECONDS"
  done
}

# --print-borrow-path: offline helper mode (see header) — no cluster access,
# no loop, no other side effects.
if [ "${1:-}" = "--print-borrow-path" ]; then
  command -v jq >/dev/null 2>&1 || { log error msg="jq not installed"; exit 1; }
  borrow_limit_path
  exit 0
fi

main "$@"
