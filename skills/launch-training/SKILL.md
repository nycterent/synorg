---
name: launch-training
description: Launch a preemptible GPU training workload on the synorg platform — interview for the run's values, scaffold a schema-valid file, validate it with the repo's own gate, pre-flight the team's onboarding, and open the PR. PR-first and credential-free: the skill proposes (a pull request), it never applies to a cluster. Trigger on "launch a training workload", "submit a training run", "run a training job on synorg", or /launch-training.
---

# Launch a training workload on synorg

You are helping an R&D engineer launch a **preemptible training job** on the
synorg platform. synorg's contract is that **git is the only write API** and
agents are principals that *propose*, never *apply* — so your terminal action is
a pull request, never `kubectl`. A merged training-run values file is a
namespace-scoped non-prod change: the autonomous capability tier auto-merges it,
the `training-runs` ApplicationSet syncs it, the Job is created suspended, and
Kueue admits it when the borrowing curve has headroom.

Run these steps in order. Each references a companion file in `references/`;
read it when you reach that step. **Never run `kubectl`, `helm ... apply`, or any
cluster write — this skill only produces a values file and a PR.**

1. **Interview + scaffold** — `references/interview.md`. Read
   `charts/training-job/values.schema.json`, prompt for the required and
   high-value fields, default `queue = team-<team>`, and emit a values file
   matching `charts/training-job/ci/basic-training.yaml`.
2. **Pre-flight** — `references/preflight.md`. Confirm the `team-<team>`
   LocalQueue exists (team onboarded), the non-negotiable labels render, and the
   engineer has acknowledged the checkpoint contract. A missing LocalQueue is a
   **hard stop** pointing at `runbooks/training-onboarding.md` — you detect
   onboarding, you do not provision it.
3. **Validate** — `references/validate.md`. Run the repo's own
   `scripts/validate.sh` (the `make validate` gate). On a named error, loop back
   to step 1 and fix the offending field. Never proceed to a PR on a failed gate.
4. **Submit** — `references/submit.md`. Write the values file under
   `clusters/<region>/training-runs/`, open a PR with `gh pr create`, and report
   the PR URL plus what happens on merge.

If the engineer would rather do it by hand, or needs to onboard a brand-new team
first, point them at `runbooks/training-onboarding.md` — this skill is the guided
on-ramp to that same runbook, not a replacement for it.

## Guardrails you enforce

- **PR-only.** No cluster credentials, no `kubectl`, no direct apply — ever.
- **The chart schema is the source of truth.** Drive the interview and the
  scaffold from `charts/training-job/values.schema.json`; never hardcode the
  field list.
- **Detect, don't provision.** Missing team onboarding stops the flow with a
  runbook pointer; you do not create namespaces, LocalQueues, or PVCs (those are
  cluster-scoped, a different capability tier).
- **Andon.** A failed validation or pre-flight halts the line — fix, then
  continue. Never open a PR for a run you could not validate.
