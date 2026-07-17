#!/usr/bin/env bash
# run.sh — e2e tier driver: the real-GPU proof (U7, R3).
#
# Stands up a spot-GPU pilot via scripts/deploy.sh (the same path `make deploy`
# takes), runs the lend/reclaim/scrub/preemption physics + game-day assertions
# (tests/e2e/assertions.sh), and tears everything down. The execution runsheet
# is runbooks/e2e-gpu-run.md — read it BEFORE the first live run; it carries
# the gotchas (ReservedCapacity feature gate, DCGM relabel, kube-state-metrics
# pod-label allowlist, balloon floor, spot quota) as ordered steps.
#
# Phases (one per invocation, or the default full cycle):
#   --check   prereqs only: tools, AWS credentials (sts), quota sanity hints.
#             Refuses (rc!=0) without credentials. NO cloud calls beyond
#             `sts get-caller-identity` + `service-quotas get-service-quota`.
#   --up      deploy the pilot (scripts/deploy.sh --auto-approve) + readiness.
#   --test    run tests/e2e/assertions.sh against the live pilot.
#   --down    tear down (terraform destroy, reverse order; ODCR NEVER destroyed
#             here — releasing held capacity is human-gated, capacity-carve.md).
#   (none)    full cycle: confirm prompt -> up -> test -> down. Teardown is
#             trap-guarded: a failed test phase still tears down unless
#             E2E_KEEP=1. Auto-confirm with E2E_CONFIRM=yes (workflow_dispatch).
#
# Zero-net-capacity-release invariant (U6 guard pattern, capacity-carve.md):
# the capacity-reservation ledger (total/held per declared reservation) is
# snapshotted at entry and asserted UNCHANGED at exit — the e2e run may consume
# and return slots, but may never release held capacity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# --- Config (env-overridable; defaults mirror scripts/deploy.sh) -------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
PILOT_CONTEXT="${PILOT_CONTEXT:-synorg-pilot}"
MGMT_CONTEXT="${MGMT_CONTEXT:-synorg-mgmt}"
# Module dirs (ODCR_DIR/MGMT_DIR/PILOT_DIR/CKPT_DIR) + the shared ledger
# reader come from the same lib scripts/deploy.sh uses.
# shellcheck source=scripts/lib/ledger.sh
source "$ROOT/scripts/lib/ledger.sh"

E2E_STATE_DIR="${E2E_STATE_DIR:-build/e2e}"    # snapshots + logs (workflow artifact)
E2E_CONFIRM="${E2E_CONFIRM:-}"                 # yes = skip the interactive confirm
E2E_KEEP="${E2E_KEEP:-0}"                      # 1 = leave the pilot up on failure
E2E_UP_TIMEOUT="${E2E_UP_TIMEOUT:-2700}"       # seconds for deploy + node readiness

# Spot GPU vCPU quota (g5/g6 land here). Runsheet Step 2 names these; --check
# only DESCRIBES them (read-only) and hints, it never requests an increase.
SPOT_GVT_QUOTA_CODE="L-3819A6DF"     # "All G and VT Spot Instance Requests" (vCPUs)
ONDEMAND_GVT_QUOTA_CODE="L-DB2E81BA" # "Running On-Demand G and VT instances" (vCPUs)
MIN_GPU_VCPUS_HINT="${MIN_GPU_VCPUS_HINT:-48}" # 1x g6.12xlarge + headroom

usage() {
  cat <<'EOF'
usage: tests/e2e/run.sh [--check|--up|--test|--down] [--help]

Real-GPU e2e tier (U7): deploy a spot-GPU pilot, prove the lend/reclaim/scrub/
preemption physics + the game-day gate, tear down. Runsheet:
runbooks/e2e-gpu-run.md (READ IT FIRST — quota, feature gate, relabel gotchas).

  --check   prereqs only (tools, credentials, quota hints); refuses without
            AWS credentials; makes no cloud call beyond sts + quota describe.
  --up      deploy the pilot via scripts/deploy.sh --auto-approve.
  --test    run tests/e2e/assertions.sh against the live pilot.
  --down    terraform destroy in reverse order (ODCR excluded — human-gated).
  (none)    full cycle with confirm prompt; teardown trap-guarded on failure.

Environment:
  E2E_CONFIRM=yes  auto-confirm the full cycle (workflow_dispatch sets this)
  E2E_KEEP=1       keep the pilot up when a phase fails (debugging)
  E2E_STATE_DIR    snapshots/logs dir (default build/e2e)
  AWS_REGION       region (default eu-west-1); PILOT_CONTEXT/MGMT_CONTEXT as
                   in scripts/deploy.sh

This spends real money and touches real capacity. The zero-net-release ledger
(capacity-reservation totals) is snapshotted at entry and must be unchanged at
exit — any drift is a hard failure.
EOF
}

# --- Helpers (mirrors scripts/validate.sh) ----------------------------------
fail() { echo "E2E FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — required for the e2e tier"; }
step() { echo; echo "==> $*"; }

PHASE="full"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) PHASE="check" ;;
    --up) PHASE="up" ;;
    --test) PHASE="test" ;;
    --down) PHASE="down" ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
  shift
done

mkdir -p "$E2E_STATE_DIR"

# --- Credential gate: before ANY cloud mutation (same rule as deploy.sh) -----
# Every phase needs credentials; --check IS the gate plus hints. A missing or
# invalid credential chain (including fake AWS_* env) fails at sts, rc!=0,
# before anything is planned, applied, or queried further.
gate() {
  need aws; need terraform; need kubectl; need helm; need jq; need yq; need curl
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    fail "no AWS credentials (aws sts get-caller-identity failed) — \
authenticate first (aws sso login / export AWS_PROFILE=...), then re-run. \
No cloud call was made beyond sts; nothing was deployed or mutated."
  fi
}

# --- Zero-net-release ledger (U6 guard pattern, capacity-carve.md) -----------
# ledger_read (scripts/lib/ledger.sh, shared with deploy.sh's guard) prints one
# "key id declared total held" line per declared reservation, from the ODCR
# module's declared_instance_counts/reservation_ids outputs — the same sources
# scripts/deploy.sh guard_zero_net_release verifies. These hooks keep this
# script's error wording.
ledger_fail_missing_id() { fail "ledger: no reservation id for '$1' — ODCR capture incomplete"; }
ledger_fail_describe() { fail "ledger: cannot describe $1"; }

# ledger_capture FILE — snapshot the ledger to FILE; the "none" sentinel keeps
# the entry/exit diff meaningful when no reservations are declared.
ledger_capture() {
  local out
  out="$(ledger_read)" || exit 1
  if [ -z "$out" ]; then
    echo "none - 0 0" > "$1"
  else
    printf '%s\n' "$out" > "$1"
  fi
}

LEDGER_ENTRY_FILE="$E2E_STATE_DIR/ledger-entry.txt"

ledger_snapshot_entry() {
  step "ledger: entry snapshot (zero-net-release invariant)"
  ledger_capture "$LEDGER_ENTRY_FILE"
  sed 's/^/  entry: /' "$LEDGER_ENTRY_FILE"
}

ledger_assert_unchanged() {
  step "ledger: exit assertion (zero-net-release invariant)"
  [ -f "$LEDGER_ENTRY_FILE" ] || fail "ledger: no entry snapshot at $LEDGER_ENTRY_FILE — cannot prove zero net release"
  local now_file="$E2E_STATE_DIR/ledger-exit.txt"
  ledger_capture "$now_file"
  if ! diff -u "$LEDGER_ENTRY_FILE" "$now_file"; then
    fail "zero-net-release VIOLATED: reservation totals/held changed across the \
e2e run — STOP, follow runbooks/capacity-carve.md abort semantics before anything else"
  fi
  echo "PASS: ledger unchanged (total/held per reservation identical at entry and exit)"
}

# --- Phases ------------------------------------------------------------------
phase_check() {
  step "check: tools + credentials + quota sanity (no mutation, no deploy)"
  gate
  echo "credentials OK: $(aws sts get-caller-identity --query Arn --output text)"
  # Quota sanity HINTS (read-only). g5/g6 spot capacity draws from the
  # G-and-VT spot vCPU quota; a default (often 0) quota means Karpenter can
  # never launch the fleet. Runsheet Step 2 covers requesting the increase.
  local spot_q od_q
  spot_q="$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code "$SPOT_GVT_QUOTA_CODE" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")"
  od_q="$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code "$ONDEMAND_GVT_QUOTA_CODE" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")"
  echo "spot G/VT vCPU quota   ($SPOT_GVT_QUOTA_CODE): $spot_q  (want >= $MIN_GPU_VCPUS_HINT)"
  echo "on-dem G/VT vCPU quota ($ONDEMAND_GVT_QUOTA_CODE): $od_q  (ReservedCapacity fallback path)"
  case "$spot_q" in
    unknown) echo "HINT: could not read the spot quota — check service-quotas IAM, then runsheet Step 2" ;;
    *) awk -v q="$spot_q" -v m="$MIN_GPU_VCPUS_HINT" 'BEGIN { if (q+0 < m+0) print "HINT: spot G/VT quota below " m " vCPUs — request an increase (runsheet Step 2) BEFORE --up or the fleet will not launch" }' ;;
  esac
  echo "CHECK OK — prereqs satisfied; next: runbooks/e2e-gpu-run.md Steps 3-6, then --up"
}

phase_up() {
  step "up: deploy the spot-GPU pilot (scripts/deploy.sh, runbook order)"
  gate
  # ODCR is applied WITHOUT -auto-approve by design (deploy.sh); for e2e the
  # capture must be pre-existing (no changes => terraform does not prompt) —
  # runsheet Step 1. All other modules auto-approve.
  bash scripts/deploy.sh --auto-approve
  step "up: wait for GPU nodes schedulable + balloon floor (bounded)"
  local deadline=$(( $(date +%s) + E2E_UP_TIMEOUT ))
  until kubectl --context "$PILOT_CONTEXT" get nodes 2>/dev/null | grep -q ' Ready'; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "up: no Ready node within ${E2E_UP_TIMEOUT}s"
    sleep 15
  done
  kubectl --context "$PILOT_CONTEXT" -n platform-system rollout status \
    deploy/warm-floor-balloon --timeout=600s \
    || fail "up: warm-floor balloon not scheduling — runsheet Step 6 (floor) before testing"
  echo "UP OK — pilot live; next: --test"
}

phase_test() {
  step "test: physics + game-day assertions (tests/e2e/assertions.sh)"
  gate
  [ -f "$LEDGER_ENTRY_FILE" ] || ledger_snapshot_entry   # standalone --test still gets a baseline
  # shellcheck source=tests/e2e/assertions.sh
  . tests/e2e/assertions.sh
  e2e_assert_all || fail "one or more assertions failed (see FAIL lines above)"
  echo "TEST OK — all assertions passed"
}

phase_down() {
  step "down: teardown in reverse order (ckpt -> pilot -> mgmt; ODCR kept)"
  gate
  # ODCR is deliberately NOT destroyed: releasing held capacity is irreversible
  # and human-gated (capacity-carve.md). Destroying the fleet returns slots to
  # the reservation — totals stay constant, which the ledger assertion proves.
  local dir
  for dir in "$CKPT_DIR" "$PILOT_DIR" "$MGMT_DIR"; do
    terraform -chdir="$dir" init -input=false
    terraform -chdir="$dir" destroy -input=false -auto-approve
  done
  echo "DOWN OK — pilot destroyed; held reservations untouched"
}

# --- Full cycle: confirm -> up -> test -> down, trap-guarded ------------------
TEARDOWN_DONE=0

confirm_or_die() {
  [ "$E2E_CONFIRM" = "yes" ] && return 0
  echo "This deploys a REAL spot-GPU pilot in $REGION: real money, real capacity."
  echo "Runsheet first: runbooks/e2e-gpu-run.md (quota + feature-gate + relabel steps)."
  printf "Type 'run-e2e' to continue: "
  local answer=""
  read -r answer || true
  [ "$answer" = "run-e2e" ] || fail "not confirmed — nothing was deployed"
}

# Trap-guarded teardown: whatever kills the full cycle (a failed assertion, a
# deploy error, Ctrl-C), the pilot is torn down and the ledger re-asserted —
# unless E2E_KEEP=1 explicitly keeps it up for debugging.
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$TEARDOWN_DONE" = 1 ]; then exit "$rc"; fi
  if [ "$E2E_KEEP" = 1 ]; then
    echo "E2E_KEEP=1 — pilot LEFT UP (rc=$rc). Tear down later: tests/e2e/run.sh --down" >&2
    ledger_assert_unchanged || rc=1
    exit "$rc"
  fi
  echo "trap: tearing down (rc=$rc; set E2E_KEEP=1 to keep the pilot on failure)" >&2
  phase_down || { echo "trap: teardown FAILED — clean up manually (--down), then verify the ledger" >&2; rc=1; }
  ledger_assert_unchanged || rc=1
  exit "$rc"
}

phase_full() {
  gate
  confirm_or_die
  phase_check
  ledger_snapshot_entry
  trap on_exit EXIT INT TERM
  phase_up
  phase_test
  phase_down
  TEARDOWN_DONE=1
  trap - EXIT INT TERM
  ledger_assert_unchanged
  echo
  echo "E2E OK — physics + game-day proven on real GPUs; zero net capacity release held"
}

echo "e2e/run.sh: phase=$PHASE region=$REGION state=$E2E_STATE_DIR (runbooks/e2e-gpu-run.md)"
case "$PHASE" in
  check) phase_check ;;
  up)    phase_up ;;
  test)  phase_test ;;
  down)
    gate
    [ -f "$LEDGER_ENTRY_FILE" ] || ledger_snapshot_entry  # standalone --down: baseline before destroy
    phase_down
    ledger_assert_unchanged
    ;;
  full)  phase_full ;;
esac
