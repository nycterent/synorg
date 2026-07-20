# Step 3 — Validate with the repo's own gate

Gate the run on the **same** validation CI runs — never a re-implementation, so
the skill's "valid" and CI's "valid" can't diverge.

Run the repo's diff-scoped gate from the repo root:

```bash
scripts/validate.sh        # the `make validate` entrypoint:
                           # helm template → kubeconform → kyverno test
```

The scaffolded run file lives under `clusters/<region>/training-runs/`, so a
diff-scoped `make validate` picks it up.

## Reading the result

- **Green (`VALIDATE OK`)** → continue to Step 4 (submit).
- **Named error** → this is Andon: **stop, do not open a PR.** Map the error back
  to the offending field and loop to Step 1 to correct it:
  - schema error naming a missing/invalid key (e.g., `image.tag` required,
    `checkpoint.intervalSeconds` exceeds 300) → re-prompt that field.
  - kyverno denial (e.g., missing `team.synorg.io/name`, an inline secret, a
    cross-tenant reference) → the values are wrong or the run is out of policy;
    explain the specific rule and fix before retrying.

Never "fix" a validation failure by hand-editing rendered manifests or bypassing
the gate — correct the **values**, re-render, re-validate. A run that can't pass
`make validate` locally will fail the same gate in CI and never merge.
