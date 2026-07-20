# Values template

Fill this from the interview and write it to
`clusters/<region>/training-runs/<run-name>.yaml` (Step 4 owns the path). Mirror
`charts/training-job/ci/basic-training.yaml`. Drop any commented optional the
engineer did not set — the chart supplies safe defaults.

```yaml
# <team> training run — <one-line purpose>. Launched via /launch-training.
team: <team>                 # required — team.synorg.io/name label
queue: team-<team>           # required — Kueue LocalQueue (default team-<team>)
gpu: <n>                     # required — GPUs per worker (>=1)
workers: <n>                 # optional — worker pods (default 1)
image:
  repository: <ghcr.io/nycterent/synorg/...>   # required
  tag: "<tag>"                                  # required
checkpoint:
  dir: /mnt/checkpoints/<team>   # optional — shared checkpoint store
  intervalSeconds: 300           # optional — schema caps at 300 (KTD12)
# command / resources / backoffLimit: omit to take the chart's
# preemption-aware defaults unless the engineer overrides them.
```

Naming: keep `<run-name>` short and unique per run (e.g., `ml-vit-2026-07-20`);
it becomes the ArgoCD Application name (`<region>-run-<run-name>`) and the PR
subject.

**Do not** add `namespace:`, labels, or Kueue annotations by hand — the chart
renders them from `team`/`queue`. Adding them raw invites the exact
tenancy/label mistakes the platform denies at admission.
