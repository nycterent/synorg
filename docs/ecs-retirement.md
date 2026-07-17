# ECS retirement (final state)

The migration ends when ECS holds zero workloads and is deleted. This is the
completion of R3 and the R4/R11 end state: **one** deploy interface, **zero**
bespoke DSLs. This doc defines "done" and the final PR.

## Path to zero

The web fleet follows the proven strangler path (`runbooks/service-migration.md`)
in risk-ordered waves — stateless services first. Each wave uses the U13 playbook
**unchanged**; divergence means the playbook was wrong and is fixed there, not
forked per fleet. There is no GPU complexity on the web fleet, so the render-path
carve (U15) does not apply — only traffic moves.

A service leaves ECS only after it converts: 100% on EKS at ECS-baseline parity
(p95 + error rate), soaked, its row filled in `docs/env-spec-retirement.md`, and
its env-spec deleted.

## Final state (definition of done)

1. **Every** service runs on EKS from golden-service values under
   `clusters/<region>/services/` or `clusters/<region>/web/`. No service has an
   ECS target group taking traffic.
2. **ECS clusters are empty and deleted.** No task definitions, no services, no
   ASGs backing them. For GPU: all held capacity has been carved into the EKS
   fleet with zero net release across the transition (ledger in
   `docs/capacity-transition.md`).
3. **The bridge tool is removed.** `tools/env-spec-bridge/` is deleted; no
   env-spec files remain anywhere in the repo.
4. **env-spec is dead.** `make validate` rejects any env-spec artifact — the only
   deploy path is a golden values file. Every row in
   `docs/env-spec-retirement.md` has an `env-spec deleted` date.
5. **Zero bespoke DSLs (R11).** The golden-service chart + `values.schema.json`
   is the whole deploy interface; there is no second config language and no
   deploy wiki.

## The retirement PR

A single PR lands the end state once every service has converted:

- Deletes `tools/env-spec-bridge/` and any remaining `*.envspec.yaml`.
- Tears down the ECS clusters and their ASGs (Terraform).
- Closes out `docs/env-spec-retirement.md` (all rows dated) and finalizes the
  capacity ledger in `docs/capacity-transition.md` (zero net release proven).

After merge, `make validate` has no env-spec to translate and no bespoke DSL to
guard — the platform is single-interface.

## Reported outcome

Per `Success Criterion 5`, deploy-path metrics (human-translation count → zero,
time-to-deploy) are reported over the final month post-retirement to confirm the
agent/human loop runs on the golden interface alone (`docs/agent-interface.md`).
