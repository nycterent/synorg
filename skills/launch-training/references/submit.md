# Step 4 — Submit the PR (the only write)

This is the skill's terminal action: a pull request. **No `kubectl`, no
`helm ... apply`, no cluster credentials.** A merged run file is what launches the
job — via the `training-runs` ApplicationSet (`clusters/mgmt/appsets/training-runs.yaml`).

## Place the file

Write the validated values file to the synced path:

```
clusters/<region>/training-runs/<run-name>.yaml
```

`<region>` is the target spoke (e.g., `pilot`); `<run-name>` is the short unique
name from the template. This is the directory the `training-runs` ApplicationSet
watches — a file here becomes one ArgoCD Application on merge.

## Open the PR

```bash
git checkout -b run/<team>-<run-name>
git add clusters/<region>/training-runs/<run-name>.yaml
git commit -m "run(<team>): <run-name> — <purpose>"
gh pr create --fill
```

Write a PR body that states, plainly: **team**, **GPUs per worker × workers**,
**image\:tag**, and a one-line confirmation of the **checkpoint contract**
(interval + resume). That is what a reviewer (or the autonomous tier) needs to
see.

## Report what happens on merge

Tell the engineer, and hand them the PR URL:

> On merge, this is a namespace-scoped non-prod change → the **autonomous**
> capability tier auto-merges it → the `training-runs` ApplicationSet syncs it →
> the Job is created **suspended** → **Kueue admits it when the borrowing curve
> has headroom.** If it stays suspended, inference is holding the floor right now;
> it will admit when the lending window opens. Watch with
> `kubectl -n team-<team> get workloads.kueue.x-k8s.io` — read-only, and the one
> place the runbook (`runbooks/training-onboarding.md` Step 6) says you may look.

## Failure handling

- **`gh` unauthenticated / PR fails** → the values file is already written and
  valid; tell the engineer it's preserved locally and give the manual
  `gh pr create` command. Do not leave half-state; do not fall back to a cluster
  apply.
- **Dry-run / preview requested** → show the diff and the target path; do not
  open the PR.
