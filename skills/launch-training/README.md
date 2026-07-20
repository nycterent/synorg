# launch-training skill

The guided on-ramp for an R&D engineer launching a preemptible GPU **training
job** on synorg — without reading the whole platform.

It interviews for the run's values (driven by
`charts/training-job/values.schema.json`), scaffolds a schema-valid file,
pre-flights the team's onboarding, validates with the repo's own `make validate`
gate, and opens a pull request. That's it.

## The contract

- **PR-first, credential-free.** The skill proposes a pull request; it never runs
  `kubectl` or applies to a cluster. A merged run file is what launches the job,
  through the `training-runs` ApplicationSet — git is the only write API.
- **Detect, don't provision.** It stops with a runbook pointer if the team isn't
  onboarded; it does not create namespaces, LocalQueues, or PVCs.
- **The chart schema is the source of truth.** The interview and validation come
  straight from the chart — nothing is hardcoded here to drift.

## When to reach past it

Use `runbooks/training-onboarding.md` directly to **onboard a new team** (the
namespace, LocalQueue, and checkpoint PVC the skill only checks for), or when you
want the manual step-by-step. The skill encodes that runbook's Step 6; it does
not replace Steps 1–5.

## Flow

`interview → pre-flight → validate → PR` — one correction loop at the validation
gate, no path that touches cluster credentials. See `SKILL.md` for the step
detail and `references/` for each step.
