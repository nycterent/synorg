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

## What break-glass cannot do: un-lend a node

Break-glass buys a *submission* path, never a *capacity* path. Removing the
`lending.synorg.io/lent` taint from a node would hand it back to inference
without the reclaim path — no drain, no NodeClaim delete, no scrub — so the
returning GPU still holds the borrower's VRAM and processes. R25 excluded that
from break-glass; `policies/vap/deny-lent-taint-removal.yaml` now enforces it.

Admission rejects the taint removal (and any weakening of its effect) for every
principal except the lending controller's ServiceAccount, no matter how much
node access the operator holds:

```
$ kubectl taint node <n> lending.synorg.io/lent-
Error from server (Forbidden): ... ValidatingAdmissionPolicy 'deny-lent-taint-removal' ... denied request
```

Still available in an emergency, unchanged: `kubectl cordon`, `kubectl drain`,
adding taints, and deleting the Node object outright. Those take a node *out*
of service, which is always safe; only putting a lent one *back* is blocked.

If capacity is genuinely the emergency, the lever is the schedule, not the
node: close the window in `clusters/pilot/lending/schedule.yaml` (a PR — the
only write path for lending intent) and let the controller run the reclaim.
Faster than a PR only when the controller is itself dead — and a dead
controller means the lent taints are frozen, which is the safe failure
direction: training keeps running, inference stays off the lent nodes.
