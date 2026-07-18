# Runbook: training-intake break-glass (hub down)

**When to use:** the mgmt hub (MultiKueue front door) has been down for
more than 4 hours AND a training job is genuinely urgent (ADR 0004).
Otherwise: wait — running jobs are unaffected, and intake resumes with the
hub.

**Pilot note:** until the hub exists, spoke-direct submission is the
normal path and this runbook is a no-op.

## Steps

1. Confirm the outage is the hub, not the spoke: `kubectl --context
   <spoke> -n kueue-system get pods` healthy while the mgmt context is
   unreachable.
2. Pick the target spoke deliberately — you are doing the arbitrage by
   hand. Check its lendable headroom: `kubectl --context <spoke> get
   clusterqueue training-borrow -o jsonpath='{.status.flavorsReservation}'`.
3. Submit the Job directly against the spoke, exactly as the pilot does:
   queue label `team-<name>`, `priorityClassName: training-preemptible`,
   region-local checkpoint bucket (ADR 0003 — the job is now sticky to
   this region).
4. The spoke's Kueue enforces borrowingLimit as always — no special
   permissions, no quota bypass exists on this path.
5. When the hub returns, do nothing: the job stays spoke-owned to
   completion. New submissions return to the hub.

**Never:** patch quota objects to make room, submit inference through any
queue, or leave this path as a team's default (it bypasses arbitrage).
