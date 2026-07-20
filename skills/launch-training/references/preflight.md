# Step 2 — Pre-flight (detect, don't provision)

Read-only checks before validation. You **detect** platform state; you never
create it — namespaces, LocalQueues, and PVCs are cluster-scoped resources on a
different capability tier, owned by `runbooks/training-onboarding.md`.

## 1. Is the team onboarded? (hard gate)

A training run needs a `team-<team>` LocalQueue to route through Kueue. Use the
committed LocalQueue manifests as the onboarding proxy:

```bash
grep -rl "name: team-<team>" clusters/pilot/kueue/localqueue-*.yaml
```

- **Found** → the team is onboarded; continue.
- **Not found** → **hard stop.** Tell the engineer the team isn't onboarded and
  point them at `runbooks/training-onboarding.md` Steps 1–5 (namespace,
  LocalQueue, required labels, checkpoint PVC). Do not scaffold a run for a team
  that can't receive it, and do not create the LocalQueue yourself.

## 2. Do the non-negotiable labels render?

Render the run and confirm the guardrail labels are present (the chart sets them
from `team`/`queue`, but verify — a hand-tampered values file could drop them):

```bash
helm template check charts/training-job -f <run-file> \
  | grep -E 'team.synorg.io/name|kueue.x-k8s.io/queue-name'
```

Both must appear. If either is missing, the values were tampered with — return to
Step 1. (Kyverno also denies this at validation, but catching it here gives a
clearer message.)

## 3. Checkpoint contract acknowledged?

Re-confirm from Step 1: the engineer affirms their image checkpoints under
`CHECKPOINT_DIR` and resumes from the latest checkpoint. If they can't confirm,
**block** and explain — a run that can't resume wastes GPU on every preemption,
which is the common case on the lendable pool, not the exception.

Only when all three pass do you proceed to Step 3 (validate).
