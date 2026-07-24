#!/usr/bin/env bash
# reconcile.sh — U4 thin lending controller (v0). A kubectl-driven loop that
# actuates the git-controlled lending schedule (clusters/pilot/lending/
# schedule.yaml, mounted as a ConfigMap): per tick it
#   1. fires any due reclaim wave (waves run BEFORE taint reconcile so a
#      window closing at a wave's startsAt — wave-3 06:30 == closesAt 06:30 —
#      still sees the lent taints the selection keys on): cordon+drain the
#      selected lent nodes and delete their NodeClaims (EKS); on a cluster
#      without Karpenter (kind) it LOGS the intended action only — the
#      ClusterRole has no nodes:delete and kind has no NodeClaims, by design.
#      A wave fires at most once per local day (fired-waves marker under
#      KUBECTL_CACHE_DIR) and selection excludes already-cordoned nodes, so a
#      re-fire can never re-count in-flight reclaims,
#   2. reconciles the lent taint on lendable-pool Node objects to the current
#      window state. A window CLOSE never bare-untaints a lent node: each one
#      routes through the same reclaim path the waves use (reclaim_node) and
#      is untainted only on the explicitly logged degraded paths,
#   3. patches the training ClusterQueue borrowingLimit to the curve value for
#      the current time (gpuLimitPct x current lendable GPU capacity),
#   4. enforces borrower drain (ADR 0008): while the reclaim phase is in
#      force (open window past its first wave's startsAt) every Workload
#      feeding the borrowing ClusterQueue is deactivated and annotation-
#      marked; outside the phase exactly the marked ones are reactivated.
#
# WRITE SURFACE (drift trap, plan-001 U8): Node objects, the training
# ClusterQueue, and borrowing Workloads (spec.active + drained annotation)
# only. NEVER NodePool templates — Karpenter drift-detects a template change
# and replaces the whole pool at every window transition.
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
#                       emptyDir mounted at /tmp (default /tmp/kubectl-cache).
#                       Also holds the fired-waves/ once-per-day markers: they
#                       survive container restarts (same pod) but a pod
#                       replacement clears the emptyDir and can allow one
#                       re-fire — accepted v0 caveat
#   EMIT_EVENTS         emit Kubernetes Events per action (default true)
#   WAVE_FIRE_WINDOW_SECONDS  how long after startsAt a wave stays due (default 300)
#   MAX_TICKS           stop after N ticks; 0 = run forever (test hook)
set -euo pipefail

SCHEDULE_FILE="${SCHEDULE_FILE:-/etc/lending/schedule.yaml}"
TICK_SECONDS="${TICK_SECONDS:-60}"
KUBECTL_CACHE_DIR="${KUBECTL_CACHE_DIR:-/tmp/kubectl-cache}"
EMIT_EVENTS="${EMIT_EVENTS:-true}"
WAVE_FIRE_WINDOW_SECONDS="${WAVE_FIRE_WINDOW_SECONDS:-300}"
MAX_TICKS="${MAX_TICKS:-0}"
# The never-lent warm-floor pool name (audit P0-2). validate_schedule refuses any
# schedule whose targets.lendablePool is this pool, so a typo can never aim the
# cordon/drain/delete machinery at the inference insurance floor (R2).
WARM_FLOOR_POOL="${WARM_FLOOR_POOL:-gpu-warm-floor}"

# kc — the single kubectl entrypoint (see RBAC-CHECK CONTRACT above).
# --request-timeout bounds every single API request (sibling smoke.sh/test.sh
# convention) so a stalled API server can never wedge the tick loop forever.
# Long *operations* are unaffected: drain's --timeout waits span many short
# requests (eviction creates + pod-gone polls), each individually under 30s,
# and the loop uses no watch-style single long request.
kc() { kubectl --cache-dir="$KUBECTL_CACHE_DIR" --request-timeout=30s "$@"; }

# In-pod, kubectl's in-cluster-config fallback is SKIPPED whenever any config
# override flag is set: clientcmd only falls back when the merged kubeconfig
# equals the bare defaults, and kc's --request-timeout makes it "non-default"
# — every call then dials the localhost:8080 default and the controller goes
# blind (observed live on EKS; kind test.sh runs out-of-pod with a kubeconfig,
# so the blind spot never showed there). Materialize the in-cluster identity
# as an explicit kubeconfig so kc's flags can't disable it. token-file (not an
# inline token) so the kubelet-rotated bound token is re-read per request.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
materialize_incluster_kubeconfig() {
  [ -z "${KUBECONFIG:-}" ] && [ -f "$SA_DIR/token" ] || return 0
  export KUBECONFIG="$KUBECTL_CACHE_DIR/kubeconfig"
  cat > "$KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}
      certificate-authority: $SA_DIR/ca.crt
users:
  - name: sa
    user:
      tokenFile: $SA_DIR/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: sa
current-context: in-cluster
EOF
}

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
  local reason="$1" kind="$2" name="$3" message="$4" api="v1" ts ns
  [ "$EMIT_EVENTS" = "true" ] || return 0
  [ "$kind" = "ClusterQueue" ] && api="kueue.x-k8s.io/v1beta1"
  # API validation requires event.namespace == involvedObject.namespace; both
  # kinds emitted here (Node, ClusterQueue) are cluster-scoped (involvedObject
  # namespace empty), and the apiserver maps that to the "default" namespace —
  # an event created anywhere else is rejected.
  ns=default
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kc create -f - >/dev/null <<EOF || log warn action=emit_event reason="$reason" msg="event create failed (non-fatal)"
apiVersion: v1
kind: Event
metadata:
  generateName: lending-controller-
  namespace: $ns
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

# valid_hm "HH:MM" — strict 24h clock time. Validation gate: a malformed time
# like "6:3x" must never reach hm_to_min — its arithmetic error inside an
# if-context (errexit suspended) reads as window-closed and would actuate the
# close path off garbage.
valid_hm() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

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
  # Guard (audit P0-2): the lendable pool must never be the never-lent warm
  # floor. A schedule aiming reclaim actuation at the warm-floor pool would
  # cordon/drain/delete the inference insurance floor (R2). Fail closed — the
  # whole tick is skipped, exactly like any other schedule_invalid.
  if [ "$(yq -r '.targets.lendablePool // ""' "$SCHEDULE_FILE")" = "$WARM_FLOOR_POOL" ]; then
    log error action=schedule_invalid file="$SCHEDULE_FILE" msg="targets.lendablePool must not be the warm-floor pool '$WARM_FLOOR_POOL' — refusing to actuate against the never-lent inference floor (R2)"
    return 1
  fi

  # Strict time/day validation: every clock field must be a valid HH:MM and
  # every day a real day name BEFORE any of them reaches window/wave/curve
  # arithmetic. Any failure skips the whole tick — malformed intent must never
  # reach either the waves or the taints.
  local n i t d
  n="$(yq -r '.windows | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    for field in opensAt closesAt; do
      t="$(yq -r ".windows[$i].$field // \"\"" "$SCHEDULE_FILE")"
      if ! valid_hm "$t"; then
        log error action=schedule_invalid file="$SCHEDULE_FILE" msg="windows[$i].$field '$t' is not a valid HH:MM time"
        return 1
      fi
    done
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in
        Sun|Mon|Tue|Wed|Thu|Fri|Sat) ;;
        *)
          log error action=schedule_invalid file="$SCHEDULE_FILE" msg="windows[$i].days entry '$d' is not a valid day name"
          return 1 ;;
      esac
    done < <(yq -r ".windows[$i].days // [] | .[]" "$SCHEDULE_FILE")
  done
  n="$(yq -r '.reclaimWaves // [] | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    t="$(yq -r ".reclaimWaves[$i].startsAt // \"\"" "$SCHEDULE_FILE")"
    if ! valid_hm "$t"; then
      log error action=schedule_invalid file="$SCHEDULE_FILE" msg="reclaimWaves[$i].startsAt '$t' is not a valid HH:MM time"
      return 1
    fi
  done
  n="$(yq -r '.borrowingLimitCurve | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    t="$(yq -r ".borrowingLimitCurve[$i].at // \"\"" "$SCHEDULE_FILE")"
    if ! valid_hm "$t"; then
      log error action=schedule_invalid file="$SCHEDULE_FILE" msg="borrowingLimitCurve[$i].at '$t' is not a valid HH:MM time"
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

# reclaim_node NODE GRACE ORIGIN KARPENTER NODECLAIMS_JSON — the single
# reclaim path, shared by the waves and the window-close transition. ORIGIN is
# a preformatted log token ("wave=<name>" or "reason=window_close").
# Returns 0 when the node was handed to Karpenter for termination (the scrub
# boundary — the Node object disappears with the instance, so no untaint must
# follow). Returns 1 on the degraded paths where the node is NOT terminated:
#   - EKS with no NodeClaim found: cordon+drain done, loud warning logged —
#     scrub-by-termination is unavailable; the node stays cordoned for
#     operator action and a close-path caller untaints it.
#   - kind (no Karpenter): reclaim_intent log only, by construction — the
#     ClusterRole grants no nodes:delete and kind has no NodeClaims.
reclaim_node() {
  local node="$1" grace="$2" origin="$3" karpenter="$4" nodeclaims_json="$5" ncl
  # RTS stage boundary (U3, R5): drain-start opens the return-to-service clock.
  # Emitted ABOVE the karpenter/kind branch so BOTH paths log it — on kind the
  # drain is log-only, but the stage marker still fires so the boundary is
  # assertable in the integration harness. Downstream RTS-by-stage recording
  # rules (clusters/pilot/observability/recording-rules.yaml) join these
  # controller stages to Karpenter NodeClaim series on nodepool+nodeclaim name.
  log info action=stage_drain_start node="$node" "$origin"
  if [ "$karpenter" = "1" ]; then
    emit_event ReclaimWaveStarted Node "$node" "reclaim ($origin): cordon+drain+nodeclaim delete"
    # Mark the reclaim BEFORE cordon (audit P0-3): this annotation is what
    # resume_incomplete_reclaims keys on to re-drive a reclaim whose process
    # died after cordon but before the NodeClaim delete. Marking first is the
    # safe order: a crash in the one-statement gap before cordon leaves the
    # node un-cordoned, which the resumer (keyed on cordoned) does NOT catch —
    # but a wave that has not yet fired re-selects it, and the next window
    # close reclaims it regardless, so that narrow gap is covered by the
    # wave/close paths rather than the resumer.
    local reclaim_ts; reclaim_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kc annotate node "$node" "lending.synorg.io/reclaiming=$reclaim_ts" --overwrite >/dev/null
    kc cordon "$node" >/dev/null
    emit_event NodeDraining Node "$node" "draining with ${grace}s grace ($origin)"
    kc drain "$node" --ignore-daemonsets --delete-emptydir-data --grace-period="$grace" --timeout="$(( grace * 3 ))s" >/dev/null \
      || log warn action=drain_incomplete node="$node" msg="drain did not finish cleanly, proceeding to nodeclaim delete"
    # RTS stage boundary (U3, R5): drain complete — the drain stage closes here.
    log info action=stage_drain_complete node="$node" "$origin"
    ncl="$(echo "$nodeclaims_json" | jq -r --arg n "$node" '.items[] | select(.status.nodeName == $n) | .metadata.name' | head -1)"
    if [ -n "$ncl" ]; then
      # Guard the delete (audit P0-3 review): errexit is suspended in every
      # reclaim_node caller (if/||true), so a failed delete would otherwise
      # fall through to a false nodeclaim_deleted log + return 0. The resumer
      # would then believe the node terminated, never park it, and re-drive it
      # every tick forever. A failed delete is degraded — return 1.
      if kc delete nodeclaim "$ncl" --wait=false >/dev/null; then
        # RTS stage boundary (U3, R5): nodeclaim-deleted is the last stage the
        # controller can observe — the Node object disappears with the instance,
        # so the reimage and orchestration-to-serving stages are derived in
        # recording rules from Karpenter NodeClaim series keyed on this name.
        log info action=stage_nodeclaim_deleted node="$node" nodeclaim="$ncl" "$origin"
        log info action=nodeclaim_deleted node="$node" nodeclaim="$ncl" "$origin" reason=NodeScrubStarted
        emit_event NodeScrubStarted Node "$node" "nodeclaim $ncl deleted; Karpenter terminates the instance (scrub boundary)"
        return 0
      fi
      log warn action=nodeclaim_delete_failed node="$node" nodeclaim="$ncl" "$origin" msg="NodeClaim delete failed — node NOT terminated; degraded, caller returns/parks it"
      return 1
    fi
    log warn action=reclaim node="$node" "$origin" msg="NO NodeClaim found — scrub-by-termination UNAVAILABLE; node cordoned+drained but returns unscrubbed, left cordoned for operator action"
    return 1
  fi
  # kind path: no Karpenter and the ClusterRole grants no nodes:delete —
  # a real deletion is impossible by construction, so log the intent.
  log info action=reclaim_intent node="$node" "$origin" msg="would cordon+drain node and delete its nodeclaim (no Karpenter on this cluster; log-only)"
  return 1
}

# resume_incomplete_reclaims POOL TAINT — crash-safety (audit P0-3). A reclaim
# is non-atomic (mark -> cordon -> drain -> delete NodeClaim); if the process
# dies mid-flight the node returns cordoned + still lent + still running
# training, and BOTH the wave selection and the close transition skip
# already-cordoned nodes as "in-flight", so nothing ever finishes it. Run first
# each tick: re-drive any lent node a reclaim cordoned (carries the
# lending.synorg.io/reclaiming marker) but never terminated, through the same
# reclaim_node path. The marker distinguishes a reclaim-cordon from an operator
# cordon, so an operator-parked node is never stomped.
resume_incomplete_reclaims() {
  local pool="$1" taint="$2" tkey teff nodes_json stranded node ncl_terminating
  local karpenter=0 nodeclaims_json='{"items":[]}'
  tkey="${taint%%=*}"; teff="${taint##*:}"
  nodes_json="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json)"
  stranded="$(echo "$nodes_json" | jq -r --arg k "$tkey" '
    .items[]
    | select(.spec.unschedulable == true)
    | select(.spec.taints // [] | any(.key == $k))
    | select((.metadata.annotations["lending.synorg.io/reclaiming"] // "") != "")
    | .metadata.name')"
  [ -n "$stranded" ] || return 0
  if kc api-versions | grep '^karpenter.sh/' >/dev/null; then karpenter=1; fi
  if [ "$karpenter" = "1" ]; then nodeclaims_json="$(kc get nodeclaims -o json)"; fi
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    # Skip a node whose NodeClaim is already terminating: a prior reclaim's
    # --wait=false delete succeeded and the node is on its way out. Re-driving
    # would re-drain a dying node and spam events every tick until it vanishes.
    ncl_terminating="$(echo "$nodeclaims_json" | jq -r --arg n "$node" \
      '.items[] | select(.status.nodeName == $n) | select(.metadata.deletionTimestamp != null) | .metadata.name' | head -1)"
    if [ -n "$ncl_terminating" ]; then
      log info action=reclaim_resume_skip node="$node" msg="NodeClaim $ncl_terminating already terminating — reclaim in progress"
      continue
    fi
    log info action=reclaim_resumed node="$node" msg="incomplete reclaim detected (cordoned + lent + reclaim marker) — re-driving"
    if reclaim_node "$node" 120 "reason=resume_incomplete" "$karpenter" "$nodeclaims_json"; then
      : # NodeClaim deleted — the node terminates and the marker goes with it.
    else
      # Degraded (no NodeClaim, delete failed, or log-only cluster): re-driving
      # cannot complete. Mirror reconcile_taints' degraded close path — untaint
      # so the lent capacity is returned and the node is no longer re-selected,
      # and clear the marker. The node stays CORDONED (unscrubbed) for operator
      # action. It is NOT left lent+unmarked, which would silently re-create the
      # very strand P0-3 fixes.
      kc taint node "$node" "$tkey:$teff-" >/dev/null 2>&1 || true
      kc annotate node "$node" lending.synorg.io/reclaiming- >/dev/null 2>&1 || true
      log info action=taint_removed node="$node" reason=NodeReturnedToProd origin=resume_incomplete
      emit_event NodeReturnedToProd Node "$node" "incomplete reclaim could not complete; lent taint removed, node left cordoned for operator action"
    fi
  done < <(echo "$stranded")
}

# reconcile_taints OPEN POOL TAINT — converge lent taint on lendable Nodes to
# the window state; emit NodeLent / NodeReturnedToProd / LendWindowOpened only
# on actual transitions (idempotent per tick). A window CLOSE never
# bare-untaints a lent node: each still-lent node routes through reclaim_node
# (the same path the waves use) and is untainted only on the explicitly
# degraded paths. Nodes already cordoned by a wave are in-flight reclaims and
# are left alone.
reconcile_taints() {
  local open="$1" pool="$2" taint="$3"
  local tkey tval teff nodes_json node has cordoned any_lent=0
  local karpenter=0 nodeclaims_json='{"items":[]}'
  tkey="${taint%%=*}"; tval="${taint#*=}"; tval="${tval%%:*}"; teff="${taint##*:}"
  nodes_json="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json)"
  if [ "$open" = "0" ] && echo "$nodes_json" | jq -e --arg k "$tkey" \
      'any(.items[]; (.spec.taints // [] | any(.key == $k)) and .spec.unschedulable != true)' >/dev/null; then
    # Close transition with still-lent, un-cordoned nodes: the reclaim path
    # needs to know whether Karpenter (the scrub boundary) is available.
    # grep reads to EOF (no -q): a -q early-exit SIGPIPEs kubectl and under
  # pipefail the whole pipeline "fails" — the controller then intermittently
  # concluded no-Karpenter ON EKS and logged waves as intent-only while real
  # reclaim fell to the window close (observed live: 28s past the ramp).
  if kc api-versions | grep '^karpenter.sh/' >/dev/null; then karpenter=1; fi
    if [ "$karpenter" = "1" ]; then nodeclaims_json="$(kc get nodeclaims -o json)"; fi
  fi
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
      cordoned="$(echo "$nodes_json" | jq -r --arg n "$node" \
        '.items[] | select(.metadata.name == $n) | .spec.unschedulable // false')"
      # Already cordoned = a wave's reclaim is in flight — do not double-act.
      [ "$cordoned" != "true" ] || continue
      # Grace matches the schedule's drainGraceSeconds default (waves carry
      # their own value; the close transition uses the same default).
      if reclaim_node "$node" 120 "reason=window_close" "$karpenter" "$nodeclaims_json"; then
        : # handed to Karpenter — the Node object disappears with the instance
      else
        # Degraded return (reclaim_node logged why): untaint so the node can
        # rejoin prod rather than sit lent past the window.
        kc taint node "$node" "$tkey:$teff-" >/dev/null
        log info action=taint_removed node="$node" taint="$taint" reason=NodeReturnedToProd
        emit_event NodeReturnedToProd Node "$node" "lending window closed: taint $taint removed"
      fi
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

# drain_phase_active TZ — 0 iff the reclaim phase is in force: an open lending
# window whose first reclaim wave's startsAt has passed (offsets measured from
# the window's opensAt, so cross-midnight windows compare correctly). With no
# reclaimWaves configured there is no phase and this never fires.
drain_phase_active() {
  local tz="$1" now_min day prev_day n i opens closes days o c dow
  local wn wi wstart first_off=99999 off pos
  wn="$(yq -r '.reclaimWaves // [] | length' "$SCHEDULE_FILE")"
  [ "$wn" -gt 0 ] || return 1
  now_min="$(hm_to_min "$(TZ="$tz" date +%H:%M)")"
  day="$(TZ="$tz" date +%a)"
  dow="$(TZ="$tz" date +%w)"
  local names=(Sun Mon Tue Wed Thu Fri Sat)
  prev_day="${names[$(( (dow + 6) % 7 ))]}"
  n="$(yq -r '.windows | length' "$SCHEDULE_FILE")"
  for (( i=0; i<n; i++ )); do
    opens="$(yq -r ".windows[$i].opensAt" "$SCHEDULE_FILE")"
    closes="$(yq -r ".windows[$i].closesAt" "$SCHEDULE_FILE")"
    days="$(yq -r ".windows[$i].days | join(\",\")" "$SCHEDULE_FILE")"
    o="$(hm_to_min "$opens")"; c="$(hm_to_min "$closes")"
    local in_window=1
    if [ "$o" -le "$c" ]; then
      case ",$days," in *",$day,"*)
        [ "$now_min" -ge "$o" ] && [ "$now_min" -lt "$c" ] && in_window=0 ;; esac
    else
      case ",$days," in *",$day,"*)
        [ "$now_min" -ge "$o" ] && in_window=0 ;; esac
      case ",$days," in *",$prev_day,"*)
        [ "$now_min" -lt "$c" ] && in_window=0 ;; esac
    fi
    [ "$in_window" -eq 0 ] || continue
    for (( wi=0; wi<wn; wi++ )); do
      wstart="$(yq -r ".reclaimWaves[$wi].startsAt" "$SCHEDULE_FILE")"
      off="$(minutes_since "$(hm_to_min "$wstart")" "$o")"
      [ "$off" -lt "$first_off" ] && first_off="$off"
    done
    pos="$(minutes_since "$now_min" "$o")"
    [ "$pos" -ge "$first_off" ] && return 0
  done
  return 1
}

# reconcile_borrower_drain TZ QUEUE — borrower drain (ADR 0008, glossary).
# Level-triggered against the reclaim phase: while the phase is in force,
# every Workload feeding the borrowing ClusterQueue is deactivated
# (spec.active=false) and marked with the lending.synorg.io/drained
# annotation; outside the phase, exactly the marked Workloads are
# reactivated and unmarked. Only annotated Workloads are ever reactivated —
# a Workload a human deactivated is not ours to resurrect. Borrower set =
# Workloads whose spec.queueName is a LocalQueue targeting QUEUE; queue-wide
# by decision (taints pin training to the lendable pool — if training ever
# gains a second pool, ADR 0008 reopens).
reconcile_borrower_drain() {
  local tz="$1" queue="$2"
  local phase=1 lqs wl_json targets name ns
  drain_phase_active "$tz" && phase=0
  lqs="$(kc get localqueues -A -o json | jq -c --arg q "$queue" '[.items[] | select(.spec.clusterQueue == $q) | {ns: .metadata.namespace, name: .metadata.name}]')"
  [ "$(echo "$lqs" | jq 'length')" -gt 0 ] || return 0
  wl_json="$(kc get workloads -A -o json)"
  if [ "$phase" -eq 0 ]; then
    targets="$(echo "$wl_json" | jq -r --argjson lqs "$lqs" '.items[] | . as $w | select([$lqs[] | select(.ns == $w.metadata.namespace and .name == $w.spec.queueName)] | length > 0) | select(.spec.active != false) | "\(.metadata.namespace) \(.metadata.name)"')"
    while IFS=' ' read -r ns name; do
      [ -n "$name" ] || continue
      kc patch workloads -n "$ns" "$name" --type=merge -p '{"spec":{"active":false},"metadata":{"annotations":{"lending.synorg.io/drained":"true"}}}' >/dev/null
      log info action=borrower_drained workload="$ns/$name" queue="$queue" reason=BorrowerDrained
      emit_event BorrowerDrained Workload "$name" "reclaim phase: deactivated borrowing Workload $ns/$name (queue $queue)"
    done <<< "$targets"
  else
    targets="$(echo "$wl_json" | jq -r '.items[] | select(.metadata.annotations["lending.synorg.io/drained"] == "true") | "\(.metadata.namespace) \(.metadata.name)"')"
    while IFS=' ' read -r ns name; do
      [ -n "$name" ] || continue
      kc patch workloads -n "$ns" "$name" --type=merge -p '{"spec":{"active":true},"metadata":{"annotations":{"lending.synorg.io/drained":null}}}' >/dev/null
      log info action=borrower_reactivated workload="$ns/$name" queue="$queue" reason=BorrowerReactivated
      emit_event BorrowerReactivated Workload "$name" "reclaim phase over: reactivated Workload $ns/$name"
    done <<< "$targets"
  fi
}

# reconcile_waves TZ POOL TAINT — fire any due reclaim wave, at most ONCE per
# scheduled occurrence: a marker file under $KUBECTL_CACHE_DIR/fired-waves/
# (<YYYY-MM-DD>-w<index>-<startsAt>, schedule-local date) records each firing,
# so a wave that stays due for WAVE_FIRE_WINDOW_SECONDS cannot re-fire every
# tick and compound ceil(fraction x currently-lent) toward 1-(1-f)^n. Markers live on
# the emptyDir: they survive container restarts but not pod replacement
# (accepted v0 caveat, see KUBECTL_CACHE_DIR note above). As a structural
# backstop, selection also excludes already-cordoned nodes, so even a re-fire
# cannot re-count in-flight reclaims. Per-node handling is reclaim_node
# (shared with the window-close path): EKS cordon+drain+NodeClaim delete;
# kind logs reclaim_intent only.
reconcile_waves() {
  local tz="$1" pool="$2" taint="$3"
  local tkey="${taint%%=*}"
  local now_min n i starts fraction grace delta lent count karpenter=0
  local fired_dir="$KUBECTL_CACHE_DIR/fired-waves" today marker
  mkdir -p "$fired_dir"
  # Cheap per-tick prune: markers older than 2 days can never match again.
  find "$fired_dir" -type f -mtime +1 -delete 2>/dev/null || true
  now_min="$(hm_to_min "$(TZ="$tz" date +%H:%M)")"
  today="$(TZ="$tz" date +%F)"
  n="$(yq -r '.reclaimWaves // [] | length' "$SCHEDULE_FILE")"
  [ "$n" -gt 0 ] || return 0
  # grep reads to EOF (no -q): a -q early-exit SIGPIPEs kubectl and under
  # pipefail the whole pipeline "fails" — the controller then intermittently
  # concluded no-Karpenter ON EKS and logged waves as intent-only while real
  # reclaim fell to the window close (observed live: 28s past the ramp).
  if kc api-versions | grep '^karpenter.sh/' >/dev/null; then karpenter=1; fi
  for (( i=0; i<n; i++ )); do
    starts="$(yq -r ".reclaimWaves[$i].startsAt" "$SCHEDULE_FILE")"
    fraction="$(yq -r ".reclaimWaves[$i].reclaimFraction" "$SCHEDULE_FILE")"
    grace="$(yq -r ".reclaimWaves[$i].drainGraceSeconds // 120" "$SCHEDULE_FILE")"
    delta="$(minutes_since "$now_min" "$(hm_to_min "$starts")")"
    [ $(( delta * 60 )) -lt "$WAVE_FIRE_WINDOW_SECONDS" ] || continue
    # Once-semantics PER OCCURRENCE: the marker keys on the wave's scheduled
    # startsAt as well as the date — a re-driven schedule (game-day rehearsal
    # compresses the same wave names onto new times, possibly several times a
    # day) is a NEW occurrence and must fire again. Keying on date+index
    # alone silently skipped every same-day re-drive: reclaim then fell to
    # the window close on every rehearsal after the first (observed live as
    # 128-242s-late reclaims with zero reclaim_wave log lines).
    marker="$fired_dir/$today-w$i-${starts/:/}"
    [ ! -e "$marker" ] || continue
    touch "$marker"
    # currently-lent nodes = lendable-pool nodes carrying the lent taint,
    # minus already-cordoned nodes (in-flight reclaims are never re-counted).
    lent="$(kc get nodes -l "karpenter.sh/nodepool=$pool" -o json \
      | jq -r --arg k "$tkey" '.items[] | select(.spec.taints // [] | any(.key == $k)) | select(.spec.unschedulable != true) | .metadata.name')"
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
    # correct even as reclaim_node deletes claims one by one.
    local node nodeclaims_json='{"items":[]}'
    if [ "$karpenter" = "1" ]; then
      nodeclaims_json="$(kc get nodeclaims -o json)"
    fi
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      # Degraded return (rc 1) is handled at window close by reconcile_taints;
      # mid-window the node simply stays lent.
      reclaim_node "$node" "$grace" "wave=$wave_name" "$karpenter" "$nodeclaims_json" || true
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
  # Order matters: waves fire BEFORE taint reconcile so a window closing at a
  # wave's startsAt (wave-3 06:30 == closesAt 06:30, and window_open reads
  # that instant as closed) still sees the lent taints its selection keys on;
  # reconcile_taints then routes any remaining lent node through the same
  # reclaim path instead of bare-untainting it.
  # Crash-safety first (audit P0-3): finish any reclaim a dead process left
  # cordoned-but-not-terminated before the waves/taints skip it as in-flight.
  resume_incomplete_reclaims "$pool" "$taint" || log warn action=tick msg="resume-reclaim reconcile failed, continuing"
  reconcile_waves "$tz" "$pool" "$taint" || log warn action=tick msg="wave reconcile failed, continuing"
  reconcile_taints "$open" "$pool" "$taint" || log warn action=tick msg="taint reconcile failed, continuing"
  reconcile_borrow_limit "$tz" "$pool" "$queue" || log warn action=tick msg="borrow-limit reconcile failed, continuing"
  reconcile_borrower_drain "$tz" "$queue" || log warn action=tick msg="borrower-drain reconcile failed, continuing"
}

main() {
  local ticks=0
  command -v yq >/dev/null 2>&1 || { log error msg="yq not installed"; exit 1; }
  command -v jq >/dev/null 2>&1 || { log error msg="jq not installed"; exit 1; }
  mkdir -p "$KUBECTL_CACHE_DIR"
  materialize_incluster_kubeconfig
  # Heartbeat contract (Deployment livenessProbe): the file's mtime says the
  # LOOP IS ALIVE — not that the tick succeeded. Touched at startup (so the
  # probe's initialDelay covers validate+first-tick without a race) and after
  # every tick below, including schedule_invalid skips and handled failures.
  touch "$KUBECTL_CACHE_DIR/heartbeat"
  trap 'log info msg="terminating"; exit 0' TERM INT
  log info msg="starting" schedule="$SCHEDULE_FILE" tick_seconds="$TICK_SECONDS"
  while :; do
    tick || log error action=tick msg="tick failed, continuing"
    # Loop-alive heartbeat: written whether tick succeeded, was skipped by
    # schedule_invalid, or failed-and-was-handled (see contract above).
    touch "$KUBECTL_CACHE_DIR/heartbeat"
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
