# ADR 0006 — Real GitOps remote; direct-sync is a retiring workaround

- **Status:** accepted (grilling session, 2026-07-19); VALIDATED same day —
  full clean-cycle e2e from zero passed 8/8 on the ApplicationSet path alone,
  and direct-sync was deleted as this ADR required. The gate also surfaced
  and fixed four latent GitOps-path defects direct-sync had masked (spoke API
  security group, team namespace delivery, hub-side observability
  Applications, selfHeal-vs-rehearsal interplay).
- **Context:** ApplicationSets have pointed at `github.com/synorg/synorg.git`
  since the hub design landed — a URL that hosted nothing. The e2e walking
  skeleton worked around the dark evidence plane with a direct-sync path
  (helm values-string extraction applied straight from the working tree),
  which is how the 2026-07-18 6/6 run deployed. A repo that claims "Git is
  the only write API" while its Git remote is fictional is not credible.
- **Decision:** **`github.com/nycterent/synorg` (public) becomes the real
  source of truth.**
  - ApplicationSets repoURL moves to the real remote; ArgoCD authenticates
    with a read-only deploy key (public repo needs none, key reserved for a
    later private split).
  - direct-sync is a documented walking-skeleton workaround, not an
    architecture. It is deleted — not flag-gated — once the GitOps path has
    been validated by a full clean-cycle e2e run pulling from the remote.
    Two deploy paths would guarantee one goes stale.
  - Until that validation run, direct-sync remains in-tree so the archived
    6/6 evidence stays reproducible from the exact commit that produced it.
- **Consequences:**
  - E2E runs require pushed commits before deploy — that friction is the
    GitOps contract, not an inconvenience to engineer around.
  - The clean-cycle validation run (standins from zero, no E2E_KEEP) is the
    gate for deleting direct-sync; it also re-proves `standins_up` and the
    fresh-deploy path.
  - Issue tracking stays local-markdown (`docs/agents/issue-tracker.md`);
    a GitHub remote for GitOps does not move issues to GitHub Issues.
