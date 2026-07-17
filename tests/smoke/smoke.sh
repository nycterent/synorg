#!/usr/bin/env bash
# smoke.sh — U5: fast health+behavior smoke against ANY live cluster.
#
# The post-deploy tier (plan R2): `make validate` proves the repo offline and
# `make integration` proves admission/scheduling on a disposable kind cluster;
# smoke asserts a LIVE cluster — kind or EKS — is healthy and still enforcing
# the platform's behavior. Unlike the integration tier it targets the CURRENT
# kubecontext (the operator's context), never a pinned harness context; set
# SMOKE_CONTEXT to aim it elsewhere explicitly.
#
# Checks (run --describe for this list without cluster access):
#   1. nodes-ready     every node reports Ready
#   2. argocd          if ArgoCD is present: every Application Synced + Healthy;
#                      absent => explicit SKIP (kind has no ArgoCD)
#   3. golden-service  charts/golden-service rendered with its ci/web values
#                      (the same inputs `make validate` renders), applied into a
#                      throwaway namespace, rolls out Ready, and its Service
#                      answers HTTP 200 through a port-forward
#   4. bad-pod-denied  the U2 known-bad fixture (inline Secret material) is
#                      DENIED at live admission AND the denial names
#                      deny-inline-secrets — an unrelated error can never fake
#                      a pass (plan R6)
#   5. metrics         if Prometheus is present: the query API answers AND the
#                      GPU-hour attribution series (team:gpu_allocated:sum,
#                      clusters/pilot/observability/recording-rules.yaml) is
#                      non-empty; absent => explicit SKIP (kind has no stack)
#
# Behavior checks are hard assertions: a down service or a bad pod passing
# admission FAILS smoke. Read-only except its own test resources — a single
# namespace (team-smoke-<rand>; team-* so the secret policy is in scope, see
# policies/kyverno/deny-inline-secrets.yaml) deleted by trap on exit.
#
# Flags / env:
#   --describe             Print the check list and exit (no cluster access).
#   SMOKE_CONTEXT=<ctx>    kubecontext to target (default: current context).
#   SMOKE_TIMEOUT=<sec>    Budget per bounded wait (default 120).
#   SMOKE_IMAGE=<img:tag>  Image for the golden-service pod (default
#                          nginxinc/nginx-unprivileged:1.27-alpine, which
#                          serves 200 on / at 8080 — the chart's ci/ registry
#                          is a placeholder nothing can pull).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

# --- --describe: the check list, no cluster, no tools -----------------------
if [ "${1:-}" = "--describe" ]; then
  cat <<'EOF'
smoke checks (context-agnostic; cloud-only components are assert-if-present):
  1. nodes-ready     Every node reports Ready.
  2. argocd          If ArgoCD present: every Application Synced + Healthy.
                     Absent -> SKIP (kind has no ArgoCD).
  3. golden-service  Render charts/golden-service with ci/web.yaml (same inputs
                     as make validate; image overridden to a pullable one),
                     apply into a throwaway team-smoke-<rand> namespace, wait
                     for rollout, assert HTTP 200 from its Service.
  4. bad-pod-denied  tests/integration/admission/fixtures/inline-secret.yaml
                     must be DENIED at live admission, naming
                     deny-inline-secrets (no vacuous pass).
  5. metrics         If Prometheus present (a :9090 Service in the
                     'observability' namespace): query API reachable AND
                     team:gpu_allocated:sum (GPU-hour attribution) non-empty.
                     Absent -> SKIP (kind has no metrics stack).

Runs against the CURRENT kubecontext; SMOKE_CONTEXT=<ctx> overrides.
Env: SMOKE_TIMEOUT (wait budget, default 120s), SMOKE_IMAGE (golden pod image).
Cleans up everything it creates (trap-deleted namespace); read-only otherwise.
EOF
  exit 0
fi

# --- Helpers (mirrors scripts/validate.sh) ----------------------------------
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so smoke runs the same everywhere"; }
step() { echo; echo "==> $*"; }

need kubectl
need helm
need jq
need curl

TIMEOUT="${SMOKE_TIMEOUT:-120}"
SMOKE_IMAGE="${SMOKE_IMAGE:-nginxinc/nginx-unprivileged:1.27-alpine}"

# All kubectl calls go through k(). Default is the CURRENT context — that is
# the point of this tier (an operator smokes whatever their kubeconfig points
# at, kind or EKS); SMOKE_CONTEXT pins one explicitly.
KCTX_ARGS=()
[ -n "${SMOKE_CONTEXT:-}" ] && KCTX_ARGS=(--context "$SMOKE_CONTEXT")
k() { kubectl ${KCTX_ARGS[@]+"${KCTX_ARGS[@]}"} "$@"; }

# --- Per-check verdict lines + summary --------------------------------------
PASS_COUNT=0; SKIP_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
skip() { echo "SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
flunk() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
# indent_err TEXT — multi-line evidence, indented, to stderr.
# shellcheck disable=SC2001  # multi-line indent; parameter expansion can't span lines
indent_err() { sed 's/^/    /' <<<"$1" >&2; }

# --- Test resources: one namespace + a temp dir, both trap-cleaned ----------
SUFFIX="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
NS="team-smoke-$SUFFIX"          # team-* prefix: in scope for deny-inline-secrets
WORK="$(mktemp -d)"
PF_PID=""                        # current port-forward, killed on stop/exit
NS_CREATED=0

stop_pf() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}
# start_pf NS SVC LOCAL REMOTE — background port-forward; caller polls readiness.
start_pf() {
  k -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PID=$!
}
cleanup() {
  stop_pf
  if [ "$NS_CREATED" = "1" ]; then
    k delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ============================================================================
# Precheck — an unreachable cluster fails everything at once, loudly.
# ============================================================================
step "cluster precheck (context: ${SMOKE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo '<none>')})"
k get nodes --request-timeout=20s >/dev/null \
  || fail "cluster not reachable — check your kubecontext (or set SMOKE_CONTEXT)"
echo "OK: cluster reachable"

k create namespace "$NS" >/dev/null || fail "cannot create test namespace $NS"
NS_CREATED=1
echo "created namespace $NS (deleted on exit)"

# ============================================================================
# 1. nodes-ready — every node reports Ready
# ============================================================================
step "1. nodes-ready"
NODES_JSON="$(k get nodes -o json)"
NODE_TOTAL="$(jq '.items | length' <<<"$NODES_JSON")"
NOT_READY="$(jq -r '.items[]
  | select(([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 0)
  | .metadata.name' <<<"$NODES_JSON")"
if [ "$NODE_TOTAL" -eq 0 ]; then
  flunk "nodes-ready — cluster reports zero nodes"
elif [ -n "$NOT_READY" ]; then
  flunk "nodes-ready — node(s) not Ready:"
  indent_err "$NOT_READY"
else
  pass "nodes-ready — $NODE_TOTAL/$NODE_TOTAL nodes Ready"
fi

# ============================================================================
# 2. argocd — assert-if-present: Applications Synced + Healthy
# ============================================================================
step "2. argocd (assert-if-present)"
if k get crd applications.argoproj.io >/dev/null 2>&1; then
  APPS_JSON="$(k get applications.argoproj.io -A -o json 2>/dev/null || echo '{"items":[]}')"
  APP_TOTAL="$(jq '.items | length' <<<"$APPS_JSON")"
  if [ "$APP_TOTAL" -eq 0 ]; then
    skip "argocd — CRD present but zero Applications (nothing to assert)"
  else
    UNHEALTHY="$(jq -r '.items[]
      | select((.status.sync.status // "Unknown") != "Synced"
               or (.status.health.status // "Unknown") != "Healthy")
      | "\(.metadata.namespace)/\(.metadata.name): sync=\(.status.sync.status // "Unknown") health=\(.status.health.status // "Unknown")"' \
      <<<"$APPS_JSON")"
    if [ -n "$UNHEALTHY" ]; then
      flunk "argocd — Application(s) not Synced/Healthy:"
      indent_err "$UNHEALTHY"
    else
      pass "argocd — $APP_TOTAL/$APP_TOTAL Applications Synced + Healthy"
    fi
  fi
else
  skip "argocd — applications.argoproj.io CRD not present (kind has no ArgoCD)"
fi

# ============================================================================
# 3. golden-service — render (validate.sh inputs), apply, Ready, HTTP 200
# ============================================================================
step "3. golden-service"
# Same render path as scripts/validate.sh section 1: the chart with its ci/
# values. Only the image (ci/ registry is an unpullable placeholder), probe
# paths (nginx-unprivileged serves 200 on /), replica count, and HPA/PDB are
# overridden — the platform surface (labels, service, selector) is the chart's.
GOLDEN_RELEASE="smoke"
GOLDEN_NAME="$GOLDEN_RELEASE-golden-service"   # <release>-<chart> per _helpers.tpl
if helm template "$GOLDEN_RELEASE" charts/golden-service \
    -f charts/golden-service/ci/web.yaml \
    --set image.repository="${SMOKE_IMAGE%:*}" \
    --set image.tag="${SMOKE_IMAGE##*:}" \
    --set replicas=1 --set hpa.enabled=false --set pdb.enabled=false \
    --set probes.liveness.path=/ --set probes.readiness.path=/ \
    >"$WORK/golden.yaml" 2>"$WORK/golden.err"; then
  # Self-check the render before touching the cluster: a helper rename must
  # fail HERE as a render error, not later as a misleading rollout timeout.
  grep -q "name: $GOLDEN_NAME" "$WORK/golden.yaml" \
    || fail "rendered golden chart lost expected name '$GOLDEN_NAME' — naming helper changed?"

  GOLDEN_OK=1
  if ! k apply -n "$NS" -f "$WORK/golden.yaml" >/dev/null 2>"$WORK/apply.err"; then
    GOLDEN_OK=0
    flunk "golden-service — apply rejected:"
    indent_err "$(cat "$WORK/apply.err")"
  elif ! k rollout status "deployment/$GOLDEN_NAME" -n "$NS" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    GOLDEN_OK=0
    flunk "golden-service — deployment not Ready within ${TIMEOUT}s:"
    indent_err "$(k get pods -n "$NS" -l "app.kubernetes.io/instance=$GOLDEN_RELEASE" 2>&1)"
  fi

  if [ "$GOLDEN_OK" = "1" ]; then
    pass "golden-service — applied and rolled out Ready"
    # In-cluster reachability via port-forward to the Service (works the same
    # on kind and EKS; no extra image pulls). Bounded: 30 x 1s attempts.
    LPORT=$((20000 + RANDOM % 10000))
    start_pf "$NS" "$GOLDEN_NAME" "$LPORT" 80
    HTTP_CODE=""
    for _ in $(seq 1 30); do
      HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$LPORT/" || true)"
      [ "$HTTP_CODE" = "200" ] && break
      sleep 1
    done
    stop_pf
    if [ "$HTTP_CODE" = "200" ]; then
      pass "golden-service — Service answered HTTP 200"
    else
      flunk "golden-service — Service did not answer 200 (last code: '${HTTP_CODE:-none}')"
    fi
  fi
else
  flunk "golden-service — helm template failed:"
  indent_err "$(cat "$WORK/golden.err")"
fi

# ============================================================================
# 4. bad-pod-denied — live admission rejects the known-bad fixture, by name
# ============================================================================
step "4. bad-pod-denied"
BAD_FIXTURE="tests/integration/admission/fixtures/inline-secret.yaml"
BAD_POLICY="deny-inline-secrets"
# The policy must be installed, or a deny assertion could pass for the wrong
# reason and an admit would mean nothing. A live platform cluster without its
# policies is a smoke FAILURE, not a skip.
if ! k get clusterpolicy "$BAD_POLICY" >/dev/null 2>&1; then
  flunk "bad-pod-denied — Kyverno ClusterPolicy '$BAD_POLICY' not installed (policies/kyverno/ missing from this cluster)"
elif OUT="$(k apply --dry-run=server -n "$NS" -f "$BAD_FIXTURE" 2>&1)"; then
  flunk "bad-pod-denied — admission ACCEPTED the known-bad fixture ($BAD_FIXTURE)"
elif grep -q "$BAD_POLICY" <<<"$OUT"; then
  pass "bad-pod-denied — DENIED by $BAD_POLICY"
else
  flunk "bad-pod-denied — rejected, but not by '$BAD_POLICY' (unrelated error, not a policy verdict):"
  indent_err "$OUT"
fi

# ============================================================================
# 5. metrics — assert-if-present: Prometheus up + attribution non-empty
# ============================================================================
step "5. metrics (assert-if-present)"
PROM_NS="${SMOKE_PROM_NAMESPACE:-observability}"   # runbooks/game-day.md read-API
PROM_SVC="$(k get svc -n "$PROM_NS" -o json 2>/dev/null \
  | jq -r '[.items[] | select(any(.spec.ports[]; .port == 9090))][0].metadata.name // empty')"
if [ -z "$PROM_SVC" ]; then
  skip "metrics — no :9090 Service in namespace '$PROM_NS' (kind has no metrics stack)"
else
  LPORT=$((20000 + RANDOM % 10000))
  start_pf "$PROM_NS" "$PROM_SVC" "$LPORT" 9090
  PROM_READY=""
  for _ in $(seq 1 15); do
    PROM_READY="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$LPORT/-/ready" || true)"
    [ "$PROM_READY" = "200" ] && break
    sleep 1
  done
  if [ "$PROM_READY" != "200" ]; then
    stop_pf
    flunk "metrics — Prometheus ($PROM_NS/$PROM_SVC) not ready (last code: '${PROM_READY:-none}')"
  else
    pass "metrics — Prometheus endpoint reachable ($PROM_NS/$PROM_SVC)"
    # GPU-hour attribution (R6): the recording rule the SLO catalog integrates.
    # Empty result => attribution is broken (kube-state-metrics pod-label
    # allowlist, the label join, or the rule itself) — a FAIL, not a shrug.
    ATTR_QUERY="team:gpu_allocated:sum"
    ATTR_LEN="$(curl -sG --max-time 10 "http://127.0.0.1:$LPORT/api/v1/query" \
      --data-urlencode "query=$ATTR_QUERY" | jq '.data.result | length' 2>/dev/null || echo "")"
    stop_pf
    if [ -n "$ATTR_LEN" ] && [ "$ATTR_LEN" -gt 0 ] 2>/dev/null; then
      pass "metrics — GPU-hour attribution non-empty ($ATTR_QUERY: $ATTR_LEN series)"
    else
      flunk "metrics — GPU-hour attribution query '$ATTR_QUERY' returned no series (recording rule or label join broken)"
    fi
  fi
fi

# --- Verdict ----------------------------------------------------------------
echo
echo "smoke: $PASS_COUNT passed, $SKIP_COUNT skipped, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || fail "$FAIL_COUNT check(s) failed"
echo "SMOKE OK"
