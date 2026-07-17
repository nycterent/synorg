# shellcheck shell=bash
# ledger.sh — shared zero-net-release ledger material (capacity-carve.md).
#
# Sourced by scripts/deploy.sh (guard_zero_net_release) and tests/e2e/run.sh
# (entry/exit ledger snapshots) so both read the SAME capacity-reservation
# ledger the same way: the ODCR module's declared_instance_counts /
# reservation_ids terraform outputs, verified against live AWS state.
#
# Contract:
#   - Callers source this after cd-ing to the repo root; the module dir
#     constants below are repo-root-relative (environment overrides win).
#   - Callers provide $REGION (AWS region for the describe call).
#   - ledger_read prints one "key id declared total held" line per declared
#     reservation (jq key order), or nothing when no reservations are declared.
#     AWS is queried ONCE for all reservation ids (no per-id calls).
#   - On a missing id or a failed describe, ledger_read calls the
#     ledger_fail_missing_id / ledger_fail_describe hooks; callers override
#     them to keep their own wording. Hooks must not return.
#
# No side effects on source: only variables and functions are defined.

# --- Terraform module roots, in runbook order --------------------------------
ODCR_DIR="${ODCR_DIR:-infra/terraform/regions/pilot/odcr}"
MGMT_DIR="${MGMT_DIR:-infra/terraform/mgmt}"
PILOT_DIR="${PILOT_DIR:-infra/terraform/regions/pilot}"
CKPT_DIR="${CKPT_DIR:-infra/terraform/regions/pilot/checkpoint-store}"

# Default error hooks — callers override these after sourcing.
ledger_fail_missing_id() { echo "ledger: no reservation id for '$1' — ODCR capture incomplete" >&2; exit 1; }
ledger_fail_describe() { echo "ledger: cannot describe $1" >&2; exit 1; }

# ledger_read — one "key id declared total held" line per declared reservation.
# Empty declared set prints nothing (rc 0); callers own the empty-case output.
ledger_read() {
  local declared ids k id line total avail
  declared="$(terraform -chdir="$ODCR_DIR" output -json declared_instance_counts 2>/dev/null || echo '{}')"
  ids="$(terraform -chdir="$ODCR_DIR" output -json reservation_ids 2>/dev/null || echo '{}')"
  if [ "$(jq 'length' <<<"$declared")" -eq 0 ]; then
    return 0
  fi
  local -a id_list=()
  for k in $(jq -r 'keys[]' <<<"$declared"); do
    id="$(jq -r --arg k "$k" '.[$k] // empty' <<<"$ids")"
    [ -n "$id" ] || ledger_fail_missing_id "$k"
    id_list+=("$id")
  done
  # ONE describe call for every declared reservation (the API takes a list).
  local resv
  resv="$(aws ec2 describe-capacity-reservations --region "${REGION:?ledger.sh: REGION unset}" \
    --capacity-reservation-ids "${id_list[@]}" --output json)" \
    || ledger_fail_describe "${id_list[*]}"
  for k in $(jq -r 'keys[]' <<<"$declared"); do
    id="$(jq -r --arg k "$k" '.[$k]' <<<"$ids")"
    line="$(jq -r --arg id "$id" \
      'first(.CapacityReservations[] | select(.CapacityReservationId == $id)
             | "\(.TotalInstanceCount) \(.AvailableInstanceCount)") // empty' <<<"$resv")"
    [ -n "$line" ] || ledger_fail_describe "$id"
    read -r total avail <<<"$line"
    echo "$k $id $(jq -r --arg k "$k" '.[$k]' <<<"$declared") $total $((total - avail))"
  done
}
