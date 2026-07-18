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
#                (tests/kind/up.sh) and assert the admission verdict.
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

# --- Helpers (mirrors scripts/validate.sh) ----------------------------------
fail() { echo "ADMISSION FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so this test matches CI"; }
step() { echo; echo "==> $*"; }

# All kubectl calls target the harness context explicitly (same rule as
# tests/kind/up.sh): the user's current context is never assumed or clobbered.
k() { kubectl --context "$KCTX" "$@"; }

WORK="$(mktemp -d)"
CREATED_NS=()
cleanup() {
  rm -rf "$WORK"
  # Delete only namespaces this run created; team-ml and friends belong to U1.
  for ns in ${CREATED_NS[@]+"${CREATED_NS[@]}"}; do
    k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
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

if [ "$RENDER_ONLY" = "1" ]; then
  step "render-only summary (kubectl phase skipped)"
  for f in "$WORK"/*.yaml; do
    case "$f" in *-rendered.yaml) continue ;; esac
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
k get validatingadmissionpolicy deny-cross-namespace-refs >/dev/null 2>&1 \
  || fail "ValidatingAdmissionPolicy 'deny-cross-namespace-refs' not installed — up.sh applies policies/vap/ (and prechecks the v1 API is served)"
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

# --- Verdict ----------------------------------------------------------------
echo
echo "admission scenarios: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || fail "$FAIL_COUNT scenario(s) returned the wrong admission verdict"
echo "ADMISSION OK"
