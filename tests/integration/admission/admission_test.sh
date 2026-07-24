#!/usr/bin/env bash
# admission_test.sh — U2: real admission tests over rendered chart output.
#
# The live-admission complement to `make validate` section 3b: where validate.sh
# runs `kyverno apply` offline over rendered charts, this applies the SAME
# rendered output to a REAL cluster with `kubectl apply --dry-run=server`, so
# the actual Kyverno validate webhooks and the ValidatingAdmissionPolicy (CEL)
# fire and return the verdict a production apply would get. Scenarios assert
# both directions — safe pods ADMITTED, unsafe pods DENIED — and every deny is
# checked for the DENYING POLICY'S NAME in the error output, so an unrelated
# failure (missing namespace, schema error) can never fake a pass (plan R6).
#
# Phases (cleanly separated):
#   1. render  — helm template the golden + training charts with the same ci/
#                values `make validate` uses; derive Pod fixtures from the
#                rendered pod templates via yq (in-memory mutations, no
#                checked-in modified charts); self-check every derivation.
#   2. kubectl — server-side dry-run each fixture against the kind harness
#                (tests/kind/up.sh) and assert the admission verdict. The
#                lent-taint scenarios (S8) additionally create two throwaway
#                Node objects, because deny-lent-taint-removal compares
#                oldObject against object on UPDATE and so needs a node that
#                already carries the taint; both are deleted on exit.
#
# Flags / env:
#   --render-only | RENDER_ONLY=1   Run phase 1 only (no cluster, no kubectl).
#   ADMISSION_TEST_CONTEXT=<ctx>    Override the kubecontext (default
#                                   kind-synorg, the U1 harness). Set it to your
#                                   current context name to run elsewhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

RENDER_ONLY="${RENDER_ONLY:-0}"
[ "${1:-}" = "--render-only" ] && RENDER_ONLY=1

KCTX="${ADMISSION_TEST_CONTEXT:-kind-synorg}"
TEST_NS="team-admission-e2e"     # team-* prefix: in scope for deny-inline-secrets
BALLOON_NS="platform-system"     # namespace the balloon Deployment declares

# S8 (deny-lent-taint-removal). Throwaway Node objects, never scheduled onto:
# the policy keys on an old-vs-new taint comparison, so the scenarios need a
# node that is already lent and one that never was. Using purpose-made nodes
# keeps the harness's real GPU workers (and anything running on them) out of it.
LENT_NODE="adm-lent-node"
PLAIN_NODE="adm-plain-node"
LENDING_SCHEDULE="clusters/pilot/lending/schedule.yaml"
LENDING_CONTROLLER="clusters/pilot/lending/lending-controller.yaml"

# --- Helpers (mirrors scripts/validate.sh) ----------------------------------
fail() { echo "ADMISSION FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so this test matches CI"; }
step() { echo; echo "==> $*"; }

# All kubectl calls target the harness context explicitly (same rule as
# tests/kind/up.sh): the user's current context is never assumed or clobbered.
k() { kubectl --context "$KCTX" "$@"; }

WORK="$(mktemp -d)"
CREATED_NS=()
CREATED_NODES=()
CREATED_LENDING_RBAC=0
cleanup() {
  rm -rf "$WORK"
  # Delete only namespaces this run created; team-ml and friends belong to U1.
  for ns in ${CREATED_NS[@]+"${CREATED_NS[@]}"}; do
    k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  # Same rule for the S8 objects: only what this run created. Node DELETE is
  # not matched by deny-lent-taint-removal (UPDATE only), so a still-lent test
  # node deletes cleanly without impersonating anyone.
  for node in ${CREATED_NODES[@]+"${CREATED_NODES[@]}"}; do
    k delete node "$node" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  if [ "$CREATED_LENDING_RBAC" = "1" ]; then
    k delete clusterrolebinding lending-controller --ignore-not-found >/dev/null 2>&1 || true
    k delete clusterrole lending-controller --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

need helm
need yq

# ============================================================================
# Phase 1 — render + derive fixtures (offline; no kubectl)
# ============================================================================
step "render: charts with their ci/ values (same inputs as make validate)"

helm template gpu-inference charts/golden-service \
  -f charts/golden-service/ci/gpu-inference.yaml >"$WORK/golden-rendered.yaml" \
  || fail "helm template golden-service/gpu-inference failed"
helm template basic-training charts/training-job \
  -f charts/training-job/ci/basic-training.yaml >"$WORK/training-rendered.yaml" \
  || fail "helm template training-job/basic-training failed"
echo "rendered: golden-service (gpu-inference), training-job (basic-training)"

step "derive: Pod fixtures from rendered pod templates (yq, in-memory)"

# pod_from_template KIND NAME IN OUT — lift .spec.template out of the rendered
# controller into a bare Pod so pod-level admission (Kyverno Pod rules + the
# pods-matching VAP) fires directly. serviceAccountName is stripped: the SA is
# a release-scoped object that doesn't exist in the test namespace, and SA
# existence IS checked at pod admission — it would mask the policy verdict.
pod_from_template() {
  local kind="$1" name="$2" in="$3" out="$4"
  POD_NAME="$name" yq eval "
    select(.kind == \"$kind\") |
    {\"apiVersion\": \"v1\", \"kind\": \"Pod\",
     \"metadata\": {\"name\": strenv(POD_NAME), \"labels\": .spec.template.metadata.labels},
     \"spec\": .spec.template.spec} |
    del(.spec.serviceAccountName)
  " "$in" >"$out"
}

pod_from_template Deployment adm-inference       "$WORK/golden-rendered.yaml"   "$WORK/inference-pod.yaml"
pod_from_template Job        adm-training        "$WORK/training-rendered.yaml" "$WORK/training-pod.yaml"

# S2: the safe inference pod, mutated in-memory to tolerate the lendable pool —
# the exact toleration tenancy-guard bars for customer-data workloads (R9).
yq eval '.metadata.name = "adm-inference-lendable" |
  .spec.tolerations += [{"key": "pool.synorg.io/lendable", "operator": "Equal", "value": "true", "effect": "NoSchedule"}]' \
  "$WORK/inference-pod.yaml" >"$WORK/inference-pod-lendable.yaml"

# S3: same pod with the team attribution label removed (require-team-label, R6).
yq eval '.metadata.name = "adm-inference-no-team" |
  del(.metadata.labels."team.synorg.io/name")' \
  "$WORK/inference-pod.yaml" >"$WORK/inference-pod-no-team.yaml"

# S5: the training pod, mutated to tolerate the never-lent warm floor —
# the toleration tenancy-guard bars for training workloads (R9/R2).
yq eval '.metadata.name = "adm-training-warmfloor" |
  .spec.tolerations += [{"key": "pool.synorg.io/warm-floor", "operator": "Equal", "value": "true", "effect": "NoSchedule"}]' \
  "$WORK/training-pod.yaml" >"$WORK/training-pod-warmfloor.yaml"

# S7: the safe inference pod with a volume naming ANOTHER team's namespace-
# encoded Secret/ConfigMap — first live exercise of the deny-cross-namespace-refs
# VAP (CEL); no offline test covers it.
yq eval '.metadata.name = "adm-crossns-secret" |
  .spec.volumes += [{"name": "crossns", "secret": {"secretName": "team-beta"}}]' \
  "$WORK/inference-pod.yaml" >"$WORK/pod-crossns-secret.yaml"
yq eval '.metadata.name = "adm-crossns-configmap" |
  .spec.volumes += [{"name": "crossns", "configMap": {"name": "team-beta"}}]' \
  "$WORK/inference-pod.yaml" >"$WORK/pod-crossns-configmap.yaml"

# --- Self-check the derivations (no vacuous fixtures) -----------------------
# If a chart or helper rename breaks a derivation, fail HERE with a fixture
# error, not later with a misleading admission verdict.
derive_check() {  # description yq-bool-expr file
  yq eval --exit-status "$2" "$3" >/dev/null 2>&1 \
    || fail "fixture derivation broke: $1 ($3)"
  echo "derived ok: $1"
}
derive_check "inference pod carries data.synorg.io/customer-data=true" \
  '.metadata.labels."data.synorg.io/customer-data" == "true"' "$WORK/inference-pod.yaml"
derive_check "inference pod carries team.synorg.io/name" \
  '.metadata.labels."team.synorg.io/name" == "vision"' "$WORK/inference-pod.yaml"
derive_check "inference pod requests nvidia.com/gpu" \
  '[.spec.containers[] | select(.resources.limits."nvidia.com/gpu" > 0)] | length > 0' "$WORK/inference-pod.yaml"
derive_check "inference pod tolerates warm-floor" \
  '[.spec.tolerations[] | select(.key == "pool.synorg.io/warm-floor")] | length == 1' "$WORK/inference-pod.yaml"
derive_check "inference pod does NOT tolerate lendable (customer-data gate)" \
  '[.spec.tolerations[] | select(.key == "pool.synorg.io/lendable")] | length == 0' "$WORK/inference-pod.yaml"
derive_check "mutated pod gained the lendable toleration" \
  '[.spec.tolerations[] | select(.key == "pool.synorg.io/lendable")] | length == 1' "$WORK/inference-pod-lendable.yaml"
derive_check "mutated pod lost the team label" \
  '.metadata.labels."team.synorg.io/name" == null' "$WORK/inference-pod-no-team.yaml"
derive_check "training pod carries workload.synorg.io/class=training" \
  '.metadata.labels."workload.synorg.io/class" == "training"' "$WORK/training-pod.yaml"
derive_check "training pod does NOT tolerate warm-floor (as rendered)" \
  '[.spec.tolerations[] | select(.key == "pool.synorg.io/warm-floor")] | length == 0' "$WORK/training-pod.yaml"
derive_check "mutated training pod gained the warm-floor toleration" \
  '[.spec.tolerations[] | select(.key == "pool.synorg.io/warm-floor")] | length == 1' "$WORK/training-pod-warmfloor.yaml"
derive_check "cross-ns pod mounts Secret named team-beta" \
  '[.spec.volumes[] | select(.secret.secretName == "team-beta")] | length == 1' "$WORK/pod-crossns-secret.yaml"
derive_check "cross-ns pod mounts ConfigMap named team-beta" \
  '[.spec.volumes[] | select(.configMap.name == "team-beta")] | length == 1' "$WORK/pod-crossns-configmap.yaml"
derive_check "balloon Deployment has team + class labels on its pod template" \
  'select(.kind == "Deployment") | .spec.template.metadata.labels."team.synorg.io/name" == "platform" and .spec.template.metadata.labels."workload.synorg.io/class" != null' \
  clusters/pilot/karpenter/warm-floor-balloon.yaml

# --- S8 fixtures: lent / never-lent Node objects -----------------------------
# deny-lent-taint-removal hard-codes the taint key and the controller identity
# in CEL (it cannot read the schedule). Derive both from the manifests that own
# them and fail here on drift — otherwise the policy could quietly guard a key
# nothing uses and every S8 scenario would still "pass".
step "derive: lent-taint identity from the schedule + controller manifests"

LENT_TAINT="$(yq -r '.data."schedule.yaml"' "$LENDING_SCHEDULE" | yq -r '.targets.lentTaint')"
[ -n "$LENT_TAINT" ] && [ "$LENT_TAINT" != "null" ] \
  || fail "could not read targets.lentTaint from $LENDING_SCHEDULE"
LENT_KEY="${LENT_TAINT%%=*}"
LENT_VALUE="${LENT_TAINT#*=}"; LENT_VALUE="${LENT_VALUE%%:*}"
LENT_EFFECT="${LENT_TAINT##*:}"
echo "schedule lentTaint: $LENT_TAINT (key=$LENT_KEY value=$LENT_VALUE effect=$LENT_EFFECT)"

VAP_FILE="policies/vap/deny-lent-taint-removal.yaml"
vap_var() {  # variable-name -> its CEL expression with the surrounding quotes stripped
  yq -r "select(.kind == \"ValidatingAdmissionPolicy\") | .spec.variables[] | select(.name == \"$1\") | .expression" \
    "$VAP_FILE" | tr -d '"' | tr -d '[:space:]'
}
[ "$(vap_var lentKey)" = "$LENT_KEY" ] \
  || fail "VAP lentKey '$(vap_var lentKey)' != schedule taint key '$LENT_KEY' ($VAP_FILE vs $LENDING_SCHEDULE)"
echo "derived ok: VAP guards the key the schedule actually flips ($LENT_KEY)"

# The exemption is an identity string; it must name the SA the controller
# Deployment actually runs as.
SA_NS="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.namespace' "$LENDING_CONTROLLER")"
SA_NAME="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$LENDING_CONTROLLER")"
DEPLOY_SA="$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.serviceAccountName' "$LENDING_CONTROLLER")"
[ "$DEPLOY_SA" = "$SA_NAME" ] \
  || fail "lending Deployment runs as '$DEPLOY_SA' but the manifest's ServiceAccount is '$SA_NAME'"
LENDING_SA="system:serviceaccount:$SA_NS:$SA_NAME"
[ "$(vap_var isLendingController)" = "request.userInfo.username==$LENDING_SA" ] \
  || fail "VAP exemption '$(vap_var isLendingController)' does not name the controller identity '$LENDING_SA'"
echo "derived ok: VAP exempts exactly $LENDING_SA"

# The two Node fixtures, built from the derived taint so they cannot drift.
cat >"$WORK/node-lent.yaml" <<EOF
apiVersion: v1
kind: Node
metadata:
  name: $LENT_NODE
  labels:
    admission-test.synorg.io/fixture: deny-lent-taint-removal
spec:
  taints:
    - key: $LENT_KEY
      value: "$LENT_VALUE"
      effect: $LENT_EFFECT
    - key: pool.synorg.io/lendable
      value: "true"
      effect: NoSchedule
EOF
cat >"$WORK/node-plain.yaml" <<EOF
apiVersion: v1
kind: Node
metadata:
  name: $PLAIN_NODE
  labels:
    admission-test.synorg.io/fixture: deny-lent-taint-removal
spec:
  taints:
    - key: pool.synorg.io/lendable
      value: "true"
      effect: NoSchedule
EOF
derive_check "lent node fixture carries the schedule's lent taint" \
  "[.spec.taints[] | select(.key == \"$LENT_KEY\")] | length == 1" "$WORK/node-lent.yaml"
derive_check "plain node fixture carries no lent taint" \
  "[.spec.taints[] | select(.key == \"$LENT_KEY\")] | length == 0" "$WORK/node-plain.yaml"

if [ "$RENDER_ONLY" = "1" ]; then
  step "render-only summary (kubectl phase skipped)"
  for f in "$WORK"/*.yaml; do
    # Node fixtures are not pods; the pod summary below would print nothing
    # meaningful for them (they are covered by their own derive_checks above).
    case "$f" in *-rendered.yaml|*/node-*.yaml) continue ;; esac
    echo "fixture: $(basename "$f")"
    yq eval '"  name=" + .metadata.name
      + " tolerations=[" + ([.spec.tolerations[]?.key] | join(",")) + "]"
      + " team=" + (.metadata.labels."team.synorg.io/name" // "-")
      + " class=" + (.metadata.labels."workload.synorg.io/class" // "-")
      + " customer-data=" + (.metadata.labels."data.synorg.io/customer-data" // "-")' "$f"
  done
  echo
  echo "ADMISSION RENDER OK (fixture derivation verified; run without --render-only against the kind harness for live admission)"
  exit 0
fi

# ============================================================================
# Phase 2 — real admission via kubectl apply --dry-run=server
# ============================================================================
need kubectl

step "cluster precheck (context $KCTX)"
k get nodes >/dev/null \
  || fail "context $KCTX not reachable — bring the harness up (bash tests/kind/up.sh) or set ADMISSION_TEST_CONTEXT"
# The policies under test must actually be installed, or every deny assertion
# would fail confusingly / every admit would pass vacuously.
for cpol in tenancy-guard require-team-label deny-inline-secrets; do
  k get clusterpolicy "$cpol" >/dev/null 2>&1 \
    || fail "Kyverno ClusterPolicy '$cpol' not installed — up.sh applies policies/kyverno/"
done
for vap in deny-cross-namespace-refs deny-lent-taint-removal; do
  k get validatingadmissionpolicy "$vap" >/dev/null 2>&1 \
    || fail "ValidatingAdmissionPolicy '$vap' not installed — up.sh applies policies/vap/ (and prechecks the v1 API is served)"
done
echo "OK: cluster reachable, policies present"

step "namespaces"
ensure_ns() {
  if ! k get namespace "$1" >/dev/null 2>&1; then
    k create namespace "$1" >/dev/null
    CREATED_NS+=("$1")
    echo "created namespace $1 (cleaned up on exit)"
  else
    echo "namespace $1 already exists (left in place)"
  fi
}
ensure_ns "$TEST_NS"
ensure_ns "$BALLOON_NS"

step "S8 setup: lending-controller RBAC + throwaway Node objects"
# The allow case impersonates the controller's ServiceAccount, and RBAC is
# checked BEFORE admission: without the controller's ClusterRole the request
# would be rejected by authorization and never reach the policy at all. Apply
# the REAL ClusterRole/ClusterRoleBinding from the controller manifest (up.sh
# does not install clusters/pilot/lending/) rather than a test-invented grant,
# so the allow case proves the shipped identity works.
ensure_lending_rbac() {
  if k get clusterrole lending-controller >/dev/null 2>&1; then
    echo "ClusterRole lending-controller already present (left in place)"
    return
  fi
  yq eval 'select(.metadata.name == "lending-controller") |
    select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")' \
    "$LENDING_CONTROLLER" >"$WORK/lending-rbac.yaml"
  derive_check "extracted ClusterRole grants nodes patch (the verb the reclaim path needs)" \
    'select(.kind == "ClusterRole") | [.rules[] | select(.resources[] == "nodes") | .verbs[] | select(. == "patch")] | length == 1' \
    "$WORK/lending-rbac.yaml"
  derive_check "extracted ClusterRoleBinding subjects the controller ServiceAccount" \
    "select(.kind == \"ClusterRoleBinding\") | [.subjects[] | select(.kind == \"ServiceAccount\" and .name == \"$SA_NAME\" and .namespace == \"$SA_NS\")] | length == 1" \
    "$WORK/lending-rbac.yaml"
  k apply -f "$WORK/lending-rbac.yaml" >/dev/null \
    || fail "could not apply the lending-controller RBAC needed by the S8 allow case"
  CREATED_LENDING_RBAC=1
  echo "applied lending-controller ClusterRole + ClusterRoleBinding (cleaned up on exit)"
}
ensure_lending_rbac

ensure_node() {
  local node="$1" file="$2"
  if k get node "$node" >/dev/null 2>&1; then
    echo "node $node already exists (left in place)"
    return
  fi
  k create -f "$file" >/dev/null || fail "could not create test node $node"
  CREATED_NODES+=("$node")
  echo "created node $node (cleaned up on exit)"
}
ensure_node "$LENT_NODE" "$WORK/node-lent.yaml"
ensure_node "$PLAIN_NODE" "$WORK/node-plain.yaml"
# The lent fixture is only meaningful if the taint actually landed — a silently
# dropped taint would make every S8 deny assertion vacuous.
k get node "$LENT_NODE" -o yaml | yq eval --exit-status \
  "[.spec.taints[] | select(.key == \"$LENT_KEY\")] | length == 1" - >/dev/null \
  || fail "node $LENT_NODE does not carry $LENT_KEY in the cluster — S8 would be vacuous"

# --- Assertion helpers ------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
flunk() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
# indent_err TEXT — print multi-line admission output indented, to stderr.
# shellcheck disable=SC2001  # multi-line indent; parameter expansion can't span lines
indent_err() { sed 's/^/    /' <<<"$1" >&2; }

# expect_admit DESC NS FILE — server dry-run must succeed.
expect_admit() {
  local desc="$1" ns="$2" file="$3" out
  if out="$(k apply --dry-run=server -n "$ns" -f "$file" 2>&1)"; then
    pass "$desc — ADMITTED"
  else
    flunk "$desc — expected ADMIT, admission rejected it:"
    indent_err "$out"
  fi
}

# expect_deny DESC NS FILE POLICY — server dry-run must fail AND the error must
# name the denying policy; a deny for any other reason is a FAIL (no vacuous
# passes, plan R6).
expect_deny() {
  local desc="$1" ns="$2" file="$3" policy="$4" out
  if out="$(k apply --dry-run=server -n "$ns" -f "$file" 2>&1)"; then
    flunk "$desc — expected DENY by '$policy', but admission ACCEPTED it"
  elif grep -q "$policy" <<<"$out"; then
    pass "$desc — DENIED by $policy"
  else
    flunk "$desc — rejected, but not by '$policy' (unrelated error, not a policy verdict):"
    indent_err "$out"
  fi
}

step "admission scenarios"
# S1: the repo's own customer-data GPU inference pod (ci/gpu-inference.yaml,
# rendered through the golden chart) is safe: warm-floor toleration only.
expect_admit "S1 customer-data GPU inference pod (rendered golden chart)" \
  "$TEST_NS" "$WORK/inference-pod.yaml"

# S2: same pod tolerating lendable → tenancy-guard (customer-data-never-on-lendable).
expect_deny "S2 customer-data pod mutated to tolerate lendable" \
  "$TEST_NS" "$WORK/inference-pod-lendable.yaml" "tenancy-guard"

# S3: GPU pod without team attribution → require-team-label.
expect_deny "S3 GPU pod with no team.synorg.io/name label" \
  "$TEST_NS" "$WORK/inference-pod-no-team.yaml" "require-team-label"

# S4: the warm-floor balloon Deployment (team+class labeled, GPU-requesting)
# must clear Kyverno's autogen Deployment rules — this is the manifest that
# holds the floor warm in production (KTD9).
expect_admit "S4 warm-floor balloon Deployment (as committed)" \
  "$BALLOON_NS" clusters/pilot/karpenter/warm-floor-balloon.yaml

# S5: rendered training pod is safe as-is (baseline proves the deny below is
# caused by the mutation, not an unrelated defect in the rendered pod)...
expect_admit "S5a training pod (rendered training chart, lendable-only)" \
  "$TEST_NS" "$WORK/training-pod.yaml"
# ...and denied the moment it tolerates the warm floor.
expect_deny "S5b training pod mutated to tolerate warm-floor" \
  "$TEST_NS" "$WORK/training-pod-warmfloor.yaml" "tenancy-guard"

# S6: inline Secret material in a team namespace → deny-inline-secrets;
# the ESO-stamped equivalent is the allowed path (R13).
expect_deny "S6a inline Secret in team namespace" \
  "$TEST_NS" "$HERE/fixtures/inline-secret.yaml" "deny-inline-secrets"
expect_admit "S6b ESO-managed Secret (external-secrets.io/managed=true)" \
  "$TEST_NS" "$HERE/fixtures/eso-managed-secret.yaml"

# S7: cross-namespace Secret/ConfigMap reference → the CEL VAP. First live
# exercise of deny-cross-namespace-refs; kubectl's error names the policy.
expect_deny "S7a pod mounting another team's Secret (team-beta)" \
  "$TEST_NS" "$WORK/pod-crossns-secret.yaml" "deny-cross-namespace-refs"
expect_deny "S7b pod mounting another team's ConfigMap (team-beta)" \
  "$TEST_NS" "$WORK/pod-crossns-configmap.yaml" "deny-cross-namespace-refs"

# --- S8: break-glass cannot un-lend a node (deny-lent-taint-removal, R25) ----
# These are Node UPDATEs, not applies, so they need their own two assertion
# helpers; the verdict rules are identical to expect_admit/expect_deny above
# (a deny must name the policy — an RBAC rejection or a schema error is a FAIL,
# never a pass).
#
# expect_update_admit DESC CMD... — the server dry-run update must succeed.
expect_update_admit() {
  local desc="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    pass "$desc — ADMITTED"
  else
    flunk "$desc — expected ADMIT, admission rejected it:"
    indent_err "$out"
  fi
}
# expect_update_deny DESC POLICY CMD... — must fail AND name the policy.
expect_update_deny() {
  local desc="$1" policy="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then
    flunk "$desc — expected DENY by '$policy', but admission ACCEPTED it"
  elif grep -q "$policy" <<<"$out"; then
    pass "$desc — DENIED by $policy"
  else
    flunk "$desc — rejected, but not by '$policy' (unrelated error, not a policy verdict):"
    indent_err "$out"
  fi
}

# The break-glass move this closes: drop the lent taint, keep the rest. A merge
# patch replaces the taint list wholesale, which is exactly what
# `kubectl taint node <n> lending.synorg.io/lent-` sends.
UNLEND_PATCH='{"spec":{"taints":[{"key":"pool.synorg.io/lendable","value":"true","effect":"NoSchedule"}]}}'
# Same escape by another route: leave the key in place but weaken the effect so
# it stops repelling owner pods.
WEAKEN_PATCH="{\"spec\":{\"taints\":[{\"key\":\"$LENT_KEY\",\"value\":\"$LENT_VALUE\",\"effect\":\"PreferNoSchedule\"}]}}"

# S8a: the operator running this test is the kind cluster-admin — an arbitrary
# principal as far as the policy is concerned. Cluster-admin is the strongest
# form of the case: even full node write cannot un-lend.
expect_update_deny "S8a operator removes the lent taint" "deny-lent-taint-removal" \
  k patch node "$LENT_NODE" --type=merge --dry-run=server -p "$UNLEND_PATCH"

# S8b: the same update from the reclaim path's own identity is admitted —
# the controller untaints on its degraded paths and must not be blocked.
expect_update_admit "S8b lending controller ($LENDING_SA) removes the lent taint" \
  k patch node "$LENT_NODE" --as "$LENDING_SA" --type=merge --dry-run=server -p "$UNLEND_PATCH"

# S8c: cordon is the node-side write `kubectl drain` performs; it touches
# spec.unschedulable, never the taints, and stays available to break-glass.
expect_update_admit "S8c emergency operator cordons the lent node (drain's node write)" \
  k patch node "$LENT_NODE" --type=merge --dry-run=server -p '{"spec":{"unschedulable":true}}'

# S8d: adding a taint (quarantine, custom drain guard) while the lent taint
# survives is still allowed — the rule constrains removal, not node control.
expect_update_admit "S8d emergency operator adds a taint, lent taint preserved" \
  k patch node "$LENT_NODE" --type=merge --dry-run=server \
  -p "{\"spec\":{\"taints\":[{\"key\":\"$LENT_KEY\",\"value\":\"$LENT_VALUE\",\"effect\":\"$LENT_EFFECT\"},{\"key\":\"ops.synorg.io/quarantine\",\"value\":\"true\",\"effect\":\"NoSchedule\"}]}}"

# S8e: weakening the effect is the same escape as removal (owner pods tolerate
# neither key nor effect, so PreferNoSchedule lets them land).
expect_update_deny "S8e operator weakens the lent taint to PreferNoSchedule" "deny-lent-taint-removal" \
  k patch node "$LENT_NODE" --type=merge --dry-run=server -p "$WEAKEN_PATCH"

# S8f: a node that never carried the taint is untouched by the policy —
# clearing its taints entirely is admitted.
expect_update_admit "S8f operator clears all taints on a never-lent node" \
  k patch node "$PLAIN_NODE" --type=merge --dry-run=server -p '{"spec":{"taints":[]}}'

# --- Verdict ----------------------------------------------------------------
echo
echo "admission scenarios: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || fail "$FAIL_COUNT scenario(s) returned the wrong admission verdict"
echo "ADMISSION OK"
