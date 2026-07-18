#!/usr/bin/env bash
# apply.sh — e2e-only "cheap run" sizing overlay (E2E_CHEAP=1, U7).
#
# Resizes the pilot's GPU surface to 1x/2x g4dn.xlarge (1x T4, 4 vCPU, spot for
# the lendable pool) so one full e2e run costs ~$5-10 instead of $30-80 — same
# physics (taints, waves, scrub, ledger), 1-GPU nodes. The checked-in
# production manifests are NEVER edited: this script transforms the LIVE
# objects (apply mode) or the checked-in YAML in memory (render mode). With
# E2E_CHEAP unset, nothing here ever runs — tests/e2e/run.sh guards every call.
#
# WHY live patches + an ApplicationSet detach (the ArgoCD-stickiness story):
#   - clusters/pilot/* (NodePools, balloon, Kueue, lending) converge via the
#     `regions` ApplicationSet (clusters/mgmt/appsets/regions.yaml) from the
#     git repo with `automated: {selfHeal: true, prune: true}` — a bare kubectl
#     patch to a NodePool is reverted on the next sync.
#   - Patching the generated Application (e.g. pilot-karpenter) does not stick
#     either: the ApplicationSet controller owns the Application spec and
#     reconciles it back to the template.
#   - The ApplicationSets THEMSELVES are unmanaged: nothing in the repo applies
#     clusters/mgmt/appsets/ via ArgoCD (the regions generator matches only
#     spoke-labelled clusters, and deploy.sh applies only argocd/install.yaml),
#     so a live patch to the ApplicationSet is the one write that sticks.
#   - Therefore: patch the ApplicationSet with ignoreApplicationDifferences on
#     /spec/syncPolicy, then drop `automated` from exactly the sizing-relevant
#     Applications (pilot-karpenter, pilot-kueue). selfHeal is off for the
#     sizing surface only; the direct object patches then hold for the run.
#   - No trace after teardown: `run.sh --down` destroys both clusters (the
#     detach dies with them); the only host-side artifact is the ODCR
#     held.tfvars this script writes, removed by `clean`.
#   - If the ApplicationSets were never bootstrapped on the hub (deploy.sh does
#     not apply them), the detach is skipped with a note — direct patches then
#     stick trivially because nothing reconciles those objects.
#
# Modes (one per invocation):
#   render        offline: transform the checked-in manifests in memory, print
#                 the resulting sizes + the coherence assertions. No cluster,
#                 no AWS, no file writes. The proof mode.
#   apply         patch the LIVE pilot objects (and detach ArgoCD sync for the
#                 sizing surface). Run AFTER scripts/deploy.sh converges.
#   write-tfvars  write $ODCR_DIR/held.tfvars declaring the 1x g4dn.xlarge
#                 capture (marker-tagged; refuses to clobber a foreign file).
#   clean         remove the marker-tagged held.tfvars (no-op otherwise).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

# Module dir constants (ODCR_DIR) — same lib run.sh/deploy.sh use.
# shellcheck source=scripts/lib/ledger.sh
source "$ROOT/scripts/lib/ledger.sh"

# --- Coherence parameters: the ONE place the cheap sizes live ----------------
# The hand-synced cross-file invariant set (docs/residual-review-findings/
# feat-eks-gpu-platform.md "Cross-file placeholder invariants") is derived from
# these four numbers, and `coherence` re-asserts it from the transformed output
# rather than trusting the arithmetic here.
CHEAP_INSTANCE_TYPE="g4dn.xlarge"       # 1x T4, 4 vCPU — the cheapest GPU node
CHEAP_GPUS_PER_NODE=1
CHEAP_WARM_FLOOR_NODES=1                # never-lent floor: one node
CHEAP_LENDABLE_NODE_LIMIT=2             # lendable pool cap: two nodes

# Derived — every downstream number comes from the four above.
CHEAP_BALLOON_REPLICAS="$CHEAP_WARM_FLOOR_NODES"                              # one balloon per floor node
CHEAP_WARM_FLOOR_GPU_LIMIT=$(( CHEAP_WARM_FLOOR_NODES * CHEAP_GPUS_PER_NODE ))
CHEAP_LENDABLE_GPU_LIMIT=$(( CHEAP_LENDABLE_NODE_LIMIT * CHEAP_GPUS_PER_NODE ))
CHEAP_ODCR_COUNT="$CHEAP_WARM_FLOOR_NODES"                                    # reserved path holds the floor
# Test-only: production is ["reserved","on-demand"]; cheap mode lets Karpenter
# take spot for the lendable pool (warm-floor keeps its committed values so the
# floor still exercises the reserved/ODCR path).
CHEAP_LENDABLE_CAPACITY_TYPES='["spot","on-demand"]'

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
CHEAP_ODCR_AZ="${CHEAP_ODCR_AZ:-${REGION}a}"

PILOT_CONTEXT="${PILOT_CONTEXT:-synorg-pilot}"
MGMT_CONTEXT="${MGMT_CONTEXT:-synorg-mgmt}"

# Marker line: `clean` deletes ONLY a file that starts with this, and
# write-tfvars refuses to overwrite a file that does not (operator-owned).
TFVARS_FILE="$ODCR_DIR/held.tfvars"
TFVARS_MARKER="# synorg-e2e-cheap-overlay — written by tests/e2e/cheap-overlay/apply.sh; removed by its 'clean' mode"

# Checked-in production manifests (read-only inputs for render mode).
LENDABLE_YAML="clusters/pilot/karpenter/nodepool-gpu-lendable.yaml"
WARMFLOOR_YAML="clusters/pilot/karpenter/nodepool-gpu-warm-floor.yaml"
BALLOON_YAML="clusters/pilot/karpenter/warm-floor-balloon.yaml"
CQ_LENDABLE_YAML="clusters/pilot/kueue/clusterqueue-platform-lendable.yaml"
CQ_BORROW_YAML="clusters/pilot/kueue/clusterqueue-training-borrow.yaml"

fail() { echo "CHEAP-OVERLAY FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — required by the cheap overlay"; }
step() { echo; echo "==> cheap-overlay: $*"; }
k() { kubectl --context "$PILOT_CONTEXT" "$@"; }
kh() { kubectl --context "$MGMT_CONTEXT" "$@"; }

# --- jq transforms (shared by render and apply — same bytes both ways) -------
# Requirements are matched BY KEY (never by index) so a reordered manifest
# cannot mis-patch; limits/quota resources are matched by name the same way
# controllers/lending/reconcile.sh finds the borrowingLimit path.
jq_nodepool_lendable() {
  jq --arg itype "$CHEAP_INSTANCE_TYPE" \
     --argjson ct "$CHEAP_LENDABLE_CAPACITY_TYPES" \
     --arg gpu "$CHEAP_LENDABLE_GPU_LIMIT" '
    .spec.template.spec.requirements |= map(
      if .key == "node.kubernetes.io/instance-type" then .values = [$itype]
      elif .key == "karpenter.sh/capacity-type" then .values = $ct
      else . end)
    | .spec.limits["nvidia.com/gpu"] = $gpu'
}
jq_nodepool_warmfloor() {
  # capacity-type untouched: the floor still prefers reserved (the cheap ODCR).
  jq --arg itype "$CHEAP_INSTANCE_TYPE" --arg gpu "$CHEAP_WARM_FLOOR_GPU_LIMIT" '
    .spec.template.spec.requirements |= map(
      if .key == "node.kubernetes.io/instance-type" then .values = [$itype]
      else . end)
    | .spec.limits["nvidia.com/gpu"] = $gpu'
}
jq_balloon() { jq --argjson r "$CHEAP_BALLOON_REPLICAS" '.spec.replicas = $r'; }
jq_cq_lendable() {
  jq --argjson q "$CHEAP_LENDABLE_GPU_LIMIT" '
    .spec.resourceGroups |= map(.flavors |= map(.resources |= map(
      if .name == "nvidia.com/gpu" then .nominalQuota = $q else . end)))'
}
jq_cq_borrow() {
  # nominalQuota stays 0 (training owns nothing outright — KTD6).
  jq --argjson q "$CHEAP_LENDABLE_GPU_LIMIT" '
    .spec.resourceGroups |= map(.flavors |= map(.resources |= map(
      if .name == "nvidia.com/gpu" then .borrowingLimit = $q else . end)))'
}

# --- Summaries + coherence (read back FROM transformed JSON, on stdin) -------
summarize_nodepool() {  # NAME < transformed-json
  jq -r --arg n "$1" '
    (.spec.template.spec.requirements | map(select(.key == "node.kubernetes.io/instance-type"))[0].values | tojson) as $it
    | (.spec.template.spec.requirements | map(select(.key == "karpenter.sh/capacity-type"))[0].values | tojson) as $ct
    | "  nodepool \($n): instance-types=\($it) capacity-types=\($ct) gpu-limit=\(.spec.limits["nvidia.com/gpu"])"'
}
summarize_balloon() {   # < transformed-json
  jq -r '"  warm-floor-balloon: replicas=\(.spec.replicas) gpu-request-per-pod=\(.spec.template.spec.containers[0].resources.requests["nvidia.com/gpu"])"'
}
summarize_cq() {        # NAME FIELD < transformed-json
  jq -r --arg n "$1" --arg f "$2" '
    [.spec.resourceGroups[].flavors[].resources[] | select(.name == "nvidia.com/gpu")][0] as $r
    | "  kueue \($n): nvidia.com/gpu \($f)=\($r[$f])"
      + (if $f != "nominalQuota" then " (nominalQuota=\($r.nominalQuota))" else "" end)'
}

# coherence J_LENDABLE J_WARMFLOOR J_BALLOON J_CQL J_CQB — assert the
# hand-synced invariant set against the TRANSFORMED documents (files holding
# one JSON doc each). Any mismatch is a hard fail.
coherence() {
  local jl="$1" jw="$2" jb="$3" jcl="$4" jcb="$5"
  local wf_limit lend_limit replicas pod_gpu nominal borrow
  wf_limit="$(jq -r '.spec.limits["nvidia.com/gpu"]' "$jw")"
  lend_limit="$(jq -r '.spec.limits["nvidia.com/gpu"]' "$jl")"
  replicas="$(jq -r '.spec.replicas' "$jb")"
  pod_gpu="$(jq -r '.spec.template.spec.containers[0].resources.requests["nvidia.com/gpu"]' "$jb")"
  nominal="$(jq -r '[.spec.resourceGroups[].flavors[].resources[] | select(.name=="nvidia.com/gpu")][0].nominalQuota' "$jcl")"
  borrow="$(jq -r '[.spec.resourceGroups[].flavors[].resources[] | select(.name=="nvidia.com/gpu")][0].borrowingLimit' "$jcb")"
  echo "COHERENCE (asserted from the transformed output, not the parameters)"
  [ $(( replicas * CHEAP_GPUS_PER_NODE )) -eq "$wf_limit" ] \
    || fail "coherence: balloon replicas ($replicas) x gpus/node ($CHEAP_GPUS_PER_NODE) != warm-floor GPU limit ($wf_limit)"
  echo "  PASS: balloon replicas ($replicas) x gpus/node ($CHEAP_GPUS_PER_NODE) == warm-floor GPU limit ($wf_limit)"
  [ "$pod_gpu" -eq "$CHEAP_GPUS_PER_NODE" ] \
    || fail "coherence: balloon per-pod GPU request ($pod_gpu) != gpus/node ($CHEAP_GPUS_PER_NODE) — a balloon must hold exactly one whole node"
  echo "  PASS: balloon per-pod GPU request ($pod_gpu) == gpus/node ($CHEAP_GPUS_PER_NODE)"
  [ "$CHEAP_ODCR_COUNT" -eq "$CHEAP_WARM_FLOOR_NODES" ] \
    || fail "coherence: ODCR declared count ($CHEAP_ODCR_COUNT) != warm-floor node count ($CHEAP_WARM_FLOOR_NODES)"
  echo "  PASS: ODCR declared count ($CHEAP_ODCR_COUNT) == warm-floor node count ($CHEAP_WARM_FLOOR_NODES)"
  { [ "$lend_limit" -eq "$nominal" ] && [ "$nominal" -eq "$borrow" ]; } \
    || fail "coherence: lendable GPU limit ($lend_limit) / platform-lendable nominalQuota ($nominal) / training-borrow borrowingLimit ($borrow) diverge"
  echo "  PASS: lendable GPU limit ($lend_limit) == platform-lendable nominalQuota ($nominal) == training-borrow borrowingLimit ($borrow)"
  [ "$lend_limit" -eq $(( CHEAP_LENDABLE_NODE_LIMIT * CHEAP_GPUS_PER_NODE )) ] \
    || fail "coherence: lendable GPU limit ($lend_limit) != $CHEAP_LENDABLE_NODE_LIMIT nodes x $CHEAP_GPUS_PER_NODE GPU"
  echo "  PASS: lendable GPU limit ($lend_limit) == $CHEAP_LENDABLE_NODE_LIMIT nodes x $CHEAP_GPUS_PER_NODE GPU (1-2 node pool)"
  echo "  NOTE: schedule.yaml gpuLimitPct needs NO overlay — the controller converts"
  echo "        pct x live lendable capacity to an absolute borrowingLimit at tick time"
  echo "        (controllers/lending/reconcile.sh reconcile_borrow_limit); no absolute"
  echo "        GPU count appears in the schedule."
}

tfvars_body() {
  cat <<EOF
$TFVARS_MARKER
#
# e2e cheap-mode ODCR declaration: ONE held g4dn.xlarge. A held ODCR bills like
# a running instance from the moment it is created — keep the carve window
# short (runbooks/e2e-gpu-run.md, cheap mode). Apply is human-gated as always
# (deploy.sh never -auto-approves the ODCR module). Only use in a sandbox
# account with NO production reservations in state: prevent_destroy hard-errors
# otherwise, by design.
held_reservations = {
  g4dn-xlarge-a = {
    instance_type     = "$CHEAP_INSTANCE_TYPE"
    availability_zone = "$CHEAP_ODCR_AZ"
    instance_count    = $CHEAP_ODCR_COUNT
  }
}
EOF
}

# --- Modes -------------------------------------------------------------------
mode_render() {
  need yq; need jq
  step "render (offline; checked-in manifests transformed in memory — cluster + files untouched)"
  local d; d="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $d now: the dir name is fixed at creation
  trap "rm -rf '$d'" EXIT
  yq -o=json '.' "$LENDABLE_YAML"  | jq_nodepool_lendable  > "$d/lendable.json"
  yq -o=json '.' "$WARMFLOOR_YAML" | jq_nodepool_warmfloor > "$d/warmfloor.json"
  yq ea -o=json 'select(.kind == "Deployment")' "$BALLOON_YAML" | jq_balloon > "$d/balloon.json"
  yq -o=json '.' "$CQ_LENDABLE_YAML" | jq_cq_lendable > "$d/cq-lendable.json"
  yq -o=json '.' "$CQ_BORROW_YAML"   | jq_cq_borrow   > "$d/cq-borrow.json"
  summarize_nodepool gpu-lendable   < "$d/lendable.json"
  summarize_nodepool gpu-warm-floor < "$d/warmfloor.json"
  summarize_balloon                 < "$d/balloon.json"
  summarize_cq platform-lendable nominalQuota  < "$d/cq-lendable.json"
  summarize_cq training-borrow  borrowingLimit < "$d/cq-borrow.json"
  echo "  odcr held.tfvars: g4dn-xlarge-a = ${CHEAP_ODCR_COUNT}x $CHEAP_INSTANCE_TYPE @ $CHEAP_ODCR_AZ"
  echo
  coherence "$d/lendable.json" "$d/warmfloor.json" "$d/balloon.json" "$d/cq-lendable.json" "$d/cq-borrow.json"
  echo
  echo "RENDER OK — production manifests unchanged on disk (transform is in-memory only)"
}

# argocd_detach — turn selfHeal off for exactly the sizing surface. See the
# header for why this is the only live write that sticks.
argocd_detach() {
  step "apply: detach ArgoCD automated sync for pilot-karpenter/pilot-kueue (selfHeal would revert the sizing patches)"
  if ! kh -n argocd get applicationset regions >/dev/null 2>&1; then
    echo "  no 'regions' ApplicationSet on the hub — nothing reconciles clusters/pilot/*; direct patches stick, detach skipped"
    return 0
  fi
  # Let per-Application syncPolicy diverge from the template without the
  # ApplicationSet controller reconciling it back.
  kh -n argocd patch applicationset regions --type=merge -p \
    '{"spec":{"ignoreApplicationDifferences":[{"jsonPointers":["/spec/syncPolicy"]}]}}' >/dev/null
  local app
  for app in pilot-karpenter pilot-kueue; do
    if kh -n argocd get application "$app" >/dev/null 2>&1; then
      kh -n argocd patch application "$app" --type=merge -p \
        '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      echo "  automated sync (selfHeal) OFF for Application $app — sizing patches will hold for the run"
    else
      echo "  Application $app not generated (spoke not registered yet?) — skipped"
    fi
  done
  echo "  scope note: only the sizing surface is detached; lending/observability/policy apps keep selfHeal"
}

# balloon_ns — the balloon Deployment's live namespace (manifests and runbooks
# disagree between 'karpenter' and 'platform-system'; resolve from the cluster).
balloon_ns() {
  k get deploy -A -l app.kubernetes.io/name=warm-floor-balloon -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null
}

mode_apply() {
  need kubectl; need jq
  step "apply: resize LIVE pilot objects to the cheap profile (run AFTER scripts/deploy.sh converged)"
  argocd_detach
  local d; d="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT
  k get nodepool gpu-lendable -o json   | jq_nodepool_lendable  > "$d/lendable.json"
  k replace -f "$d/lendable.json" >/dev/null
  k get nodepool gpu-warm-floor -o json | jq_nodepool_warmfloor > "$d/warmfloor.json"
  k replace -f "$d/warmfloor.json" >/dev/null
  local ns; ns="$(balloon_ns)"
  [ -n "$ns" ] || fail "apply: warm-floor-balloon Deployment not found in any namespace — did the deploy converge?"
  k -n "$ns" get deploy warm-floor-balloon -o json | jq_balloon > "$d/balloon.json"
  k replace -f "$d/balloon.json" >/dev/null
  k get clusterqueue platform-lendable -o json | jq_cq_lendable > "$d/cq-lendable.json"
  k replace -f "$d/cq-lendable.json" >/dev/null
  k get clusterqueue training-borrow -o json   | jq_cq_borrow   > "$d/cq-borrow.json"
  k replace -f "$d/cq-borrow.json" >/dev/null
  echo "  live objects resized:"
  summarize_nodepool gpu-lendable   < "$d/lendable.json"
  summarize_nodepool gpu-warm-floor < "$d/warmfloor.json"
  summarize_balloon                 < "$d/balloon.json"
  summarize_cq platform-lendable nominalQuota  < "$d/cq-lendable.json"
  summarize_cq training-borrow  borrowingLimit < "$d/cq-borrow.json"
  echo
  coherence "$d/lendable.json" "$d/warmfloor.json" "$d/balloon.json" "$d/cq-lendable.json" "$d/cq-borrow.json"
  echo
  echo "APPLY OK — cheap sizing live; teardown destroys the clusters, so no live-state restore is needed"
}

mode_write_tfvars() {
  step "write-tfvars: declare the cheap ODCR (1x $CHEAP_INSTANCE_TYPE) at $TFVARS_FILE"
  if [ -f "$TFVARS_FILE" ] && [ "$(head -1 "$TFVARS_FILE")" != "$TFVARS_MARKER" ]; then
    fail "refusing to overwrite $TFVARS_FILE — it exists and is not cheap-overlay-marked (operator-owned; move it aside or unset E2E_CHEAP)"
  fi
  tfvars_body > "$TFVARS_FILE"
  echo "  written (marker-tagged; 'clean' removes it). deploy.sh picks it up via -var-file automatically."
}

mode_clean() {
  step "clean: remove the cheap-overlay held.tfvars (no trace after teardown)"
  if [ -f "$TFVARS_FILE" ] && [ "$(head -1 "$TFVARS_FILE")" = "$TFVARS_MARKER" ]; then
    rm -f "$TFVARS_FILE"
    echo "  removed $TFVARS_FILE"
  else
    echo "  nothing to remove ($TFVARS_FILE absent or not cheap-overlay-marked) — no-op"
  fi
}

usage() {
  cat <<'EOF'
usage: tests/e2e/cheap-overlay/apply.sh render|apply|write-tfvars|clean

e2e-only cheap-run sizing overlay (E2E_CHEAP=1). See the header comment and
runbooks/e2e-gpu-run.md "Cheap mode" for mechanism + scope. Never run against
production manifests on disk — render is in-memory, apply targets live objects.
EOF
}

case "${1:-}" in
  render) mode_render ;;
  apply) mode_apply ;;
  write-tfvars) mode_write_tfvars ;;
  clean) mode_clean ;;
  --help|-h|help) usage ;;
  *) usage >&2; fail "unknown or missing mode: '${1:-}'" ;;
esac
