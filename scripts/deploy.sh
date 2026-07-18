#!/usr/bin/env bash
# deploy.sh — credential-gated platform bootstrap (U6, R5).
#
# One entrypoint reproducing runbooks/deploy-platform.md in its exact order:
#   §1 ODCR capture (U15)  → §2 mgmt cluster + ArgoCD (U2)
#   §3 pilot + Karpenter (U3, + checkpoint-store)  → §4 register spoke
#   §5 policy plane (U5)   → §6 scheduling/lending  → §7 evidence plane
#
# The runbook stays the authoritative narrative; this script only automates it
# and references the sections it executes. Capacity is irreversible: the
# zero-net-release guard (runbooks/capacity-carve.md verify-before-terminate)
# runs after every capacity-touching step, and the ODCR apply is always
# human-gated (never -auto-approve).
#
# Each step is idempotent and re-runnable: terraform reconciles, kubectl apply
# converges, and spoke registration pre-checks before adding — so a re-run
# after a partial apply resumes without duplicating reservations.
#
# Remote state: copy infra/terraform/backend.tf.example into each module dir
# (unique key per module) before a live apply. See that file for details.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Module roots + shared ledger reader (scripts/lib/ledger.sh) ------------
# The lib defines ODCR_DIR/MGMT_DIR/PILOT_DIR/CKPT_DIR (runbook order) and
# ledger_read, shared with tests/e2e/run.sh.
# shellcheck source=scripts/lib/ledger.sh
source "$ROOT/scripts/lib/ledger.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
# Every terraform module (odcr/mgmt/pilot/checkpoint-store) declares
# var.region with an eu-west-1 default — export it so AWS_REGION steers
# terraform too, not just the aws-cli calls below (otherwise a us-east-1 run
# would plan/apply against eu-west-1).
export TF_VAR_region="$REGION"
MGMT_CONTEXT="${MGMT_CONTEXT:-synorg-mgmt}"     # kubeconfig aliases set by
PILOT_CONTEXT="${PILOT_CONTEXT:-synorg-pilot}"  # `aws eks update-kubeconfig`

MODE="apply"          # apply | plan
DRY_RUN=0             # 1 = print the command sequence, execute nothing
AUTO_APPROVE=0        # -auto-approve for non-ODCR modules only

# Controller pins for §4.5 — keep in sync with tests/kind/up.sh (Kyverno,
# Kueue) and tests/kind/kwok-up.sh (Karpenter core version); the AWS provider
# chart is versioned in lockstep with the core.
KYVERNO_VERSION="v1.18.2"
KUEUE_VERSION="v0.18.3"
KARPENTER_VERSION="1.14.0"
NVDP_VERSION="0.17.4"   # NVIDIA k8s-device-plugin chart

usage() {
  cat <<'EOF'
usage: scripts/deploy.sh [--plan] [--dry-run] [--auto-approve] [--help]

Bootstrap the platform per runbooks/deploy-platform.md (§1-§7, in order).

  --plan          terraform plan for every module in runbook order; no apply,
                  no cluster mutation. Works with read-only AWS credentials.
  --dry-run       print the full command sequence without executing anything
                  (offline; proves the step order). Combine with --plan to see
                  the plan-mode sequence.
  --auto-approve  pass -auto-approve to terraform apply for every module
                  EXCEPT the ODCR capture — held capacity is irreversible, so
                  the ODCR apply always prompts (deploy-platform.md warning).
  --help          this text.

Environment:
  AWS_REGION      region for terraform modules + capacity/EKS calls
                  (default eu-west-1; exported as TF_VAR_region)
  MGMT_CONTEXT    kubeconfig context alias for the hub (default synorg-mgmt)
  PILOT_CONTEXT   kubeconfig context alias for the spoke (default synorg-pilot)

Refuses to run without AWS credentials (aws sts get-caller-identity) before
any terraform invocation. Every step is idempotent: re-run after a partial
apply and terraform/kubectl converge without duplicating reservations.
EOF
}

fail() { echo "DEPLOY FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — required for this mode"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) MODE="plan" ;;
    --dry-run) DRY_RUN=1 ;;
    --auto-approve) AUTO_APPROVE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
  shift
done

# -auto-approve applies only in apply mode, and never to the ODCR module
# (step_odcr passes nothing extra by design). Computed once; expanded with the
# same set-u-safe pattern the per-step locals used.
AUTO_APPROVE_ARGS=()
[ "$AUTO_APPROVE" = 1 ] && [ "$MODE" = apply ] && AUTO_APPROVE_ARGS+=(-auto-approve)

# run CMD... — execute, or print without executing under --dry-run. Every
# terraform/aws/kubectl/argocd invocation goes through this so --dry-run is a
# faithful, offline proof of the exact sequence and order.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: $*"
  else
    "$@"
  fi
}

step() { echo; echo "== $* =="; }

# --- Credential gate: before ANY terraform invocation -----------------------
# --plan needs read credentials; apply needs write. --dry-run is offline and
# skips the gate (it executes nothing).
if [ "$DRY_RUN" != 1 ]; then
  need aws
  need terraform
  need jq
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    fail "no AWS credentials (aws sts get-caller-identity failed) — \
authenticate first (aws sso login / export AWS_PROFILE=...), then re-run. \
Nothing was planned or applied."
  fi
  if [ "$MODE" = "apply" ]; then
    need kubectl; need argocd; need kyverno; need helm; need yq   # fail fast, not mid-bootstrap
  fi
fi

# tf_step DIR [EXTRA_APPLY_ARGS...] — init + plan/apply one module. In plan
# mode this never applies; in apply mode -auto-approve is the caller's choice
# (never passed for the ODCR module).
tf_step() {
  local dir="$1"; shift
  run terraform -chdir="$dir" init -input=false
  if [ "$MODE" = "plan" ]; then
    run terraform -chdir="$dir" plan -input=false "$@"
  else
    run terraform -chdir="$dir" apply -input=false "$@"
  fi
}

# --- Zero-net-release guard (runbooks/capacity-carve.md) --------------------
# Verify-before-terminate: after any capacity-touching step, every declared
# reservation must show its capacity held (utilization == declared count) and
# its total unchanged. A reservation that fails to hold is a hard stop — the
# invariant is capacity, not progress (capacity-carve.md abort semantics).
# The ledger itself is read by scripts/lib/ledger.sh (shared with the e2e
# tier); these hooks keep this script's error wording.
ledger_fail_output() { fail "zero-net-release: cannot read the ODCR ledger outputs from $1 — terraform output failed (backend.tf configured? terraform -chdir=$1 init run?); an unreadable ledger is never an empty one — STOP"; }
ledger_fail_missing_id() { fail "zero-net-release: no reservation id for '$1' — capture (§1) incomplete; STOP"; }
ledger_fail_describe() { fail "zero-net-release: cannot describe $1"; }

guard_zero_net_release() {
  step "zero-net-release guard (capacity-carve.md verify-before-terminate)"
  if [ "$DRY_RUN" = 1 ]; then
    run aws ec2 describe-capacity-reservations --region "$REGION" \
      --capacity-reservation-ids '<each reservation_ids output>' \
      --query 'CapacityReservations[0].[TotalInstanceCount,AvailableInstanceCount]'
    echo "DRY-RUN: assert total == declared_instance_counts and held == declared, else STOP"
    return 0
  fi
  local lines k id expected total held
  lines="$(ledger_read)" || exit 1
  if [ -z "$lines" ]; then
    echo "guard: no held reservations in state — nothing to verify"
    return 0
  fi
  # held == declared encodes the CARVE scenario: instances already running
  # inside the reservation (capacity-carve.md verify-before-terminate). A
  # marker-verified cheap-mode reservation is created FRESH by the run —
  # nothing consumes it until Karpenter launches — so held is legitimately 0
  # at bootstrap; for that case the secured-capacity assertion is total ==
  # declared, and held is reported informationally.
  local cheap_fresh=0
  if [ "${E2E_CHEAP:-0}" = 1 ] && [ -f "$ODCR_DIR/held.tfvars" ] \
      && head -1 "$ODCR_DIR/held.tfvars" | grep -q 'synorg-e2e-cheap-overlay'; then
    cheap_fresh=1
  fi
  while read -r k id expected total held; do
    [ "$total" -eq "$expected" ] || fail "zero-net-release: $k ($id) total=$total != declared=$expected — capacity changed; STOP, do not proceed (capacity-carve.md)"
    if [ "$cheap_fresh" = 1 ]; then
      echo "guard: $k ($id) total=$total == declared — capacity secured (cheap fresh reservation; held=$held informational)"
    else
      [ "$held" -eq "$expected" ] || fail "zero-net-release: $k ($id) holds $held of $expected declared — reservation not fully held; STOP, do not proceed (capacity-carve.md)"
      echo "guard: $k ($id) total=$total held=$held == declared — capacity held"
    fi
  done <<<"$lines"
  echo "guard: record the utilization snapshot in docs/capacity-transition.md"
}

# update_kubeconfig TFDIR ALIAS PLACEHOLDER — read cluster_name from TFDIR's
# terraform outputs (PLACEHOLDER stands in under --dry-run) and wire the
# kubeconfig alias via `aws eks update-kubeconfig`.
update_kubeconfig() {
  local tfdir="$1" alias="$2" name="$3"
  [ "$DRY_RUN" = 1 ] || name="$(terraform -chdir="$tfdir" output -raw cluster_name)"
  run aws eks update-kubeconfig --region "$REGION" --name "$name" --alias "$alias"
}

# --- §1 Capture held capacity (U15) — before anything else ------------------
step_odcr() {
  step "1/7 ODCR capture — deploy-platform.md §1 (U15)"
  local extra=()
  [ -f "$ODCR_DIR/held.tfvars" ] && extra+=(-var-file=held.tfvars)
  # Never -auto-approve here: touching live held capacity is human-gated.
  # ONE exception, mirroring the e2e teardown rule: a cheap-mode run whose
  # held.tfvars carries the cheap-overlay marker is declaring its OWN
  # disposable reservation (1x g4dn) — that run also destroys it at --down.
  # Without the marker, the human gate stands, exactly as before.
  if [ "${E2E_CHEAP:-0}" = 1 ] && [ -f "$ODCR_DIR/held.tfvars" ] \
      && head -1 "$ODCR_DIR/held.tfvars" | grep -q 'synorg-e2e-cheap-overlay'; then
    echo "  ODCR: cheap run-owned reservation (marker-verified) — auto-approving this apply"
    extra+=(-auto-approve)
  fi
  tf_step "$ODCR_DIR" ${extra[0]+"${extra[@]}"}
  [ "$MODE" = "apply" ] && guard_zero_net_release
  return 0
}

# --- §2 Management cluster + ArgoCD hub (U2) --------------------------------
step_mgmt() {
  step "2/7 mgmt cluster + ArgoCD hub — deploy-platform.md §2 (U2)"
  tf_step "$MGMT_DIR" ${AUTO_APPROVE_ARGS[0]+"${AUTO_APPROVE_ARGS[@]}"}
  [ "$MODE" = "plan" ] && return 0
  update_kubeconfig "$MGMT_DIR" "$MGMT_CONTEXT" '<mgmt cluster_name output>'
  # install.yaml is the SELF-MANAGE Application CR — it needs ArgoCD (CRDs +
  # controller) already running. Its header documents the one-time out-of-band
  # chart install; this is that step, with chart/version/values extracted FROM
  # the CR itself so the bootstrap can never drift from the git source of truth.
  local arepo achart aver avals
  arepo="$(yq '.spec.source.repoURL' clusters/mgmt/argocd/install.yaml)"
  achart="$(yq '.spec.source.chart' clusters/mgmt/argocd/install.yaml)"
  aver="$(yq '.spec.source.targetRevision' clusters/mgmt/argocd/install.yaml)"
  avals="$(mktemp)"
  yq '.spec.source.helm.valuesObject' clusters/mgmt/argocd/install.yaml > "$avals"
  run helm --kube-context "$MGMT_CONTEXT" upgrade --install argocd "$achart" \
    --repo "$arepo" --version "$aver" \
    --namespace argocd --create-namespace -f "$avals" --wait --timeout 10m
  rm -f "$avals"
  # Now ArgoCD adopts itself: the Application CR points at the same chart.
  run kubectl --context "$MGMT_CONTEXT" apply -f clusters/mgmt/argocd/install.yaml
  run kubectl --context "$MGMT_CONTEXT" -n argocd wait --for=condition=Available \
    deployment --all --timeout=600s
  # The ApplicationSets ARE the GitOps write API (regions + services). Without
  # them nothing ever generates the pilot-* Applications — first live run
  # proved the gap: the balloon never syncs and §4's convergence never comes.
  run kubectl --context "$MGMT_CONTEXT" apply -f clusters/mgmt/appsets/
}

# --- §3 Pilot region cluster + Karpenter held fleet (U3) --------------------
step_pilot() {
  step "3/7 pilot cluster + Karpenter + checkpoint-store — deploy-platform.md §3 (U3)"
  # Wire the held ODCR ARNs from the §1 outputs into the pilot fleet (the
  # odcr_reservation_arns variable) so Karpenter's IAM is scoped to exactly
  # the held reservations.
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: export TF_VAR_odcr_reservation_arns=<odcr reservation_arns output>"
  else
    local arns
    if arns="$(terraform -chdir="$ODCR_DIR" output -json reservation_arns 2>/dev/null)" \
       && [ "$(jq 'length' <<<"$arns")" -gt 0 ]; then
      TF_VAR_odcr_reservation_arns="$(jq -c '[.[]]' <<<"$arns")"
      export TF_VAR_odcr_reservation_arns
    fi
  fi
  tf_step "$PILOT_DIR" ${AUTO_APPROVE_ARGS[0]+"${AUTO_APPROVE_ARGS[@]}"}
  tf_step "$CKPT_DIR" ${AUTO_APPROVE_ARGS[0]+"${AUTO_APPROVE_ARGS[@]}"}
  [ "$MODE" = "plan" ] && return 0
  # Provisioning consumed reservation slots — re-assert nothing was released.
  guard_zero_net_release
  update_kubeconfig "$PILOT_DIR" "$PILOT_CONTEXT" '<pilot cluster_name output>'
  # The balloon/NodePool convergence checks live in §4: they can only pass
  # AFTER the spoke is registered and the regions ApplicationSet has synced
  # clusters/pilot/ onto it — at §3 nothing has synced yet (proven live).
}

# --- §4 Register the spoke with the hub -------------------------------------
step_register_spoke() {
  step "4/7 register spoke with hub — deploy-platform.md §4"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping cluster registration"; return 0; }
  # argocd runs in --core mode against a TEMP kubeconfig holding both contexts
  # with mgmt as current — no `argocd login` bootstrap (there is no API-server
  # session to create) and the operator's real kubeconfig current-context is
  # never touched.
  local akc="" acore=()
  if [ "$DRY_RUN" != 1 ]; then
    akc="$(mktemp)"
    KUBECONFIG="$HOME/.kube/config" kubectl config view --flatten --minify --context "$MGMT_CONTEXT" > "$akc"
    KUBECONFIG="$HOME/.kube/config:$akc" kubectl config view --flatten > "$akc.merged" && mv "$akc.merged" "$akc"
    # Core mode reads argocd-cm from the context's namespace — pin it.
    kubectl --kubeconfig "$akc" config set-context "$MGMT_CONTEXT" --namespace argocd >/dev/null
    kubectl --kubeconfig "$akc" config use-context "$MGMT_CONTEXT" >/dev/null
    acore=(--core)
  fi
  # Idempotency pre-check: a re-run must not re-add (or error on) the spoke.
  # (-o name is not a valid argocd output format; json+jq is version-stable.)
  if [ "$DRY_RUN" != 1 ] && KUBECONFIG="$akc" argocd "${acore[@]}" cluster list -o json 2>/dev/null | jq -r '.[].name' | grep -qx pilot; then
    echo "spoke 'pilot' already registered — skipping"
    rm -f "$akc"
    return 0
  fi
  # Scoped spoke secret (assume-role limited to this spoke, never fleet-wide
  # admin — KTD7).
  if [ "$DRY_RUN" = 1 ]; then
    run argocd cluster add "$PILOT_CONTEXT" --name pilot --label synorg.io/role=spoke
  else
    KUBECONFIG="$akc" argocd --core cluster add "$PILOT_CONTEXT" --name pilot \
      --label synorg.io/role=spoke --yes --upsert \
      || { rm -f "$akc"; fail "argocd cluster add failed (core mode)"; }
    rm -f "$akc"
  fi
}

# --- §4.5 Platform controllers on the spoke ---------------------------------
# The pilot terraform provisions Karpenter's IAM/SQS plumbing and exports the
# values "consumed by the Karpenter controller Helm values" — but nothing ever
# installed the controller, nor Kyverno, nor Kueue (the kind harness installs
# its own; the EKS side was undefined — found live). Pins match the harness.
step_controllers() {
  step "4.5/7 platform controllers on the spoke (Karpenter + Kyverno + Kueue)"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping controller installs"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version $KARPENTER_VERSION (values from pilot outputs)"
    echo "DRY-RUN: kubectl apply kyverno $KYVERNO_VERSION + kueue $KUEUE_VERSION pinned manifests; wait rollouts"
    return 0
  fi
  local cname car cqu
  cname="$(terraform -chdir="$PILOT_DIR" output -raw cluster_name)"
  car="$(terraform -chdir="$PILOT_DIR" output -raw karpenter_controller_iam_role_arn)"
  cqu="$(terraform -chdir="$PILOT_DIR" output -raw karpenter_interruption_queue_name)"
  run helm --kube-context "$PILOT_CONTEXT" upgrade --install karpenter \
    oci://public.ecr.aws/karpenter/karpenter --version "$KARPENTER_VERSION" \
    --namespace kube-system \
    --set "settings.clusterName=$cname" \
    --set "settings.interruptionQueue=$cqu" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$car" \
    --wait --timeout 10m
  run kubectl --context "$PILOT_CONTEXT" apply --server-side --force-conflicts \
    -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
  run kubectl --context "$PILOT_CONTEXT" -n kyverno wait deploy --all --for=condition=Available --timeout=300s
  run kubectl --context "$PILOT_CONTEXT" apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
  run kubectl --context "$PILOT_CONTEXT" -n kueue-system rollout status deploy/kueue-controller-manager --timeout=300s
  # NVIDIA device plugin: the accelerated AMI ships the drivers, but the
  # nvidia.com/gpu resource is only advertised by the plugin DaemonSet —
  # which nothing installed (found live: GPU node Ready, zero GPUs
  # allocatable). Tolerations cover the pool taints, mirroring what the kind
  # harness patches onto the fake operator.
  run helm --kube-context "$PILOT_CONTEXT" upgrade --install nvidia-device-plugin nvidia-device-plugin \
    --repo https://nvidia.github.io/k8s-device-plugin --version "$NVDP_VERSION" \
    --namespace kube-system \
    --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"},{"key":"pool.synorg.io/warm-floor","operator":"Exists","effect":"NoSchedule"},{"key":"pool.synorg.io/lendable","operator":"Exists","effect":"NoSchedule"},{"key":"lending.synorg.io/lent","operator":"Exists","effect":"NoSchedule"}]' \
    --set-json 'affinity={"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"pool.synorg.io/name","operator":"In","values":["warm-floor","lendable"]}]}]}}}'
  # ^ the chart's default affinity keys on nvidia.com/gpu.present (a GPU
  # Feature Discovery label we don't run) — DESIRED was 0 on a live GPU
  # node; our pool labels are the truth here.
}

# --- §4.6 Sync clusters/pilot/ onto the spoke + convergence ------------------
step_sync() {
  step "4.6/7 sync clusters/pilot/ + convergence (balloon, NodePools)"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping sync"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: wait for warm-floor-balloon (platform-system) + NodePools on the spoke (<=10m)"
    return 0
  fi
  # DEPLOY_DIRECT_SYNC=1 (e2e/no-remote bootstrap): the ApplicationSets point
  # at the canonical repo remote; when that remote is unreachable (this repo
  # is local-only today) the GitOps loop cannot deliver clusters/pilot/. The
  # e2e's subject is the GPU physics, not the sync plumbing — direct-apply the
  # same manifests the ApplicationSet would, and say so LOUDLY: with this set,
  # the ArgoCD sync path itself is NOT being exercised.
  if [ "${DEPLOY_DIRECT_SYNC:-0}" = 1 ]; then
    echo "DIRECT-SYNC: applying clusters/pilot/ straight to the spoke — GitOps sync path NOT exercised this run"
    # ArgoCD's CreateNamespace=true sync option makes namespaces; a bare
    # kubectl apply does not — pre-create every namespace the manifests
    # declare (derived from the manifests, not a hand list).
    local ns
    for ns in $(grep -rh 'namespace:' clusters/pilot/ | awk '{print $2}' | sort -u); do
      kubectl --context "$PILOT_CONTEXT" get namespace "$ns" >/dev/null 2>&1 \
        || run kubectl --context "$PILOT_CONTEXT" create namespace "$ns"
    done
    # Curated, not blind -R: services/ holds helm VALUES files (not
    # manifests), and observability/prometheus-stack.yaml holds hub-side
    # ArgoCD Application CRs whose sync source is the (absent) git remote.
    local d
    for d in karpenter kueue lending; do
      run kubectl --context "$PILOT_CONTEXT" apply --server-side --force-conflicts -R -f "clusters/pilot/$d/"
    done
    # The lending-controller manifest pins the canonical registry.synorg.io
    # image, which is not pushed anywhere yet — a direct-sync run must supply
    # the image it actually built (e.g. the run's ECR push) or the deploy
    # ends in ImagePullBackOff.
    if [ -n "${DEPLOY_LENDING_IMAGE:-}" ]; then
      run kubectl --context "$PILOT_CONTEXT" -n lending set image \
        deploy/lending-controller "controller=$DEPLOY_LENDING_IMAGE"
    fi
    # Observability: install the same charts the Application CRs pin —
    # specs yq-extracted from the CRs so nothing drifts from git.
    local doc chart repo ver vals
    for doc in 0 1; do
      chart="$(yq "select(document_index == $doc) | .spec.source.chart" clusters/pilot/observability/prometheus-stack.yaml)"
      repo="$(yq "select(document_index == $doc) | .spec.source.repoURL" clusters/pilot/observability/prometheus-stack.yaml)"
      ver="$(yq "select(document_index == $doc) | .spec.source.targetRevision" clusters/pilot/observability/prometheus-stack.yaml)"
      vals="$(mktemp)"
      # helm.values is a raw YAML STRING, helm.valuesObject a structured map —
      # these CRs use `values`; extracting only valuesObject silently installed
      # the stack with NO values (retention, open rule/monitor selectors and
      # the dcgm scrape config all dropped). Accept either field.
      if [ "$(yq "select(document_index == $doc) | .spec.source.helm | has(\"values\")" clusters/pilot/observability/prometheus-stack.yaml)" = "true" ]; then
        yq -r "select(document_index == $doc) | .spec.source.helm.values" clusters/pilot/observability/prometheus-stack.yaml > "$vals"
      else
        yq "select(document_index == $doc) | .spec.source.helm.valuesObject // {}" clusters/pilot/observability/prometheus-stack.yaml > "$vals"
      fi
      # dcgm-exporter is a GPU-node DaemonSet: it cannot be Ready before the
      # first GPU node exists (the balloon provisions it AFTER this step), so
      # only the prometheus stack itself is waited on.
      local wait_args=(--wait --timeout 10m)
      [ "$chart" = "dcgm-exporter" ] && wait_args=()
      run helm --kube-context "$PILOT_CONTEXT" upgrade --install "pilot-$chart" "$chart" \
        --repo "$repo" --version "$ver" --namespace observability --create-namespace \
        -f "$vals" ${wait_args[0]+"${wait_args[@]}"}
      rm -f "$vals"
    done
    # PrometheusRule CRs (recording rules / SLOs) need the operator CRDs
    # from the stack above — apply after it.
    run kubectl --context "$PILOT_CONTEXT" apply --server-side --force-conflicts \
      -f clusters/pilot/observability/recording-rules.yaml \
      -f clusters/pilot/observability/slo-definitions.yaml
    echo "DIRECT-SYNC: services/ skipped (helm values for the golden chart — GitOps-only surface)"
  fi
  local i ok=0
  for i in $(seq 1 60); do
    if kubectl --context "$PILOT_CONTEXT" -n platform-system get deploy warm-floor-balloon >/dev/null 2>&1 \
        && [ "$(kubectl --context "$PILOT_CONTEXT" get nodepools -o name 2>/dev/null | wc -l)" -ge 1 ]; then
      ok=1; break
    fi
    sleep 10
  done
  [ "$ok" = 1 ] || fail "spoke registered but clusters/pilot/ never synced (balloon/NodePools absent after 10m) — check the regions ApplicationSet + Applications on the hub"
  run kubectl --context "$PILOT_CONTEXT" -n platform-system get deploy warm-floor-balloon
  run kubectl --context "$PILOT_CONTEXT" get nodepools
}

# --- §5 Policy plane (U5) ---------------------------------------------------
step_policy() {
  step "5/7 policy plane — deploy-platform.md §5 (U5)"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping policy apply"; return 0; }
  # Direct apply is first-bootstrap only; afterwards these converge via ArgoCD.
  run kubectl --context "$PILOT_CONTEXT" apply -f policies/kyverno/
  run kubectl --context "$PILOT_CONTEXT" apply -f policies/vap/
  run kyverno test policies/tests --detailed-results
}

# --- §6 Scheduling and lending ----------------------------------------------
step_scheduling() {
  step "6/7 scheduling + lending (converges via ArgoCD) — deploy-platform.md §6"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping convergence checks"; return 0; }
  run kubectl --context "$PILOT_CONTEXT" get clusterqueues
  run kubectl --context "$PILOT_CONTEXT" -n lending get deploy lending-controller
  run kubectl --context "$PILOT_CONTEXT" -n lending get cm lending-schedule
  echo "NOTE: do NOT enable a real lending window until the game-day gate passes"
  echo "      (deploy-platform.md §8, runbooks/game-day.md). Schedule changes go by PR only."
}

# --- §7 Evidence plane (U9) -------------------------------------------------
step_evidence() {
  step "7/7 evidence plane — deploy-platform.md §7 (U9)"
  [ "$MODE" = "plan" ] && { echo "plan mode: skipping evidence checks"; return 0; }
  run kubectl --context "$MGMT_CONTEXT" -n argocd get applications
  echo "verify: observability apps Synced/Healthy; render-start p95, DCGM utilization,"
  echo "        and per-team GPU-hour attribution series populating (deploy-platform.md §7)"
}

echo "deploy.sh: mode=$MODE dry-run=$DRY_RUN region=$REGION (runbooks/deploy-platform.md order)"
step_odcr
step_mgmt
step_pilot
step_register_spoke
step_controllers
step_sync
step_policy
step_scheduling
step_evidence

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "DRY-RUN complete — sequence above is the exact runbook order; nothing was executed"
elif [ "$MODE" = "plan" ]; then
  echo "DEPLOY PLAN OK — every module planned in runbook order; nothing applied"
else
  echo "DEPLOY OK — next: gate on a game-day before enabling lending (deploy-platform.md §8)"
fi
