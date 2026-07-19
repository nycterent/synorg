# Capability Tiers

Policy verdicts replace human approval queues (R7). Every change lands in one of
three tiers by blast radius. Each tier is enforced by a **specific mechanism** —
either a **merge gate** (decided in CI / branch protection before the change ever
reaches the cluster) or an **admission policy** (decided by the API server when a
manifest is applied). The tier is derived from what the change touches; it is not
a label a human self-selects.

This is the KTD8 hybrid: stateless field rules run as ValidatingAdmissionPolicy
(CEL, no webhook latency); cross-resource, generation, and material checks run as
Kyverno ClusterPolicies. Both back the "never" tier at admission; the merge gate
backs the "autonomous" and "human-by-exception" tiers.

![Decision flow for a change (PR): cross-tenant reference or secret material is denied at admission (never); a prod topology, quota, or NodePool change needs a branch-protection review (human-by-exception); a namespace-scoped non-prod change, or a values-only prod change post game-day, whose policies all pass, auto-merges through make validate (autonomous)](assets/diagrams/capability-tiers.svg)

## Tiers

| Tier | What lands here | Enforcement mechanism | Where the verdict is made |
|---|---|---|---|
| **autonomous** | Namespace-scoped, non-prod changes whose policies all pass — **plus** values-only changes to existing **prod** services once that region's game-day gate has passed (routine deploys must not recreate the approval queue R7 kills). | **Merge gate** — CI runs `make validate` (helm template → kubeconform → kyverno test → rendered diff); all green → eligible for auto-merge. | CI, pre-merge |
| **human-by-exception** | Prod **topology, quota, or NodePool** changes (Karpenter NodePools, Kueue ClusterQueue quotas, cluster overlays). | **Merge gate** — branch protection requires an approving review on the affected paths. This is a **technical gate** (a required review that cannot be dismissed by the author), not a label convention. | Repo branch protection, pre-merge |
| **never** | Cross-tenant references and secret **material** in manifests. | **Admission policy** — hard deny at the API server. Cannot be merged-around: even if committed, the cluster refuses it. | Cluster admission |

## Enforcement mapping

### autonomous — merge gate (CI)
The change is admissible **and** low-blast-radius, so no human is on the path. The
gate is the validation loop itself: policies must evaluate to `pass`/`skip`, charts
must render, kubeconform must be clean. Post-game-day, a values-only prod image bump
joins this lane.

Proof fixtures (these evaluate to **pass**, so they would clear the gate):
- `policies/tests/require-team-label/` — `team-alpha/gpu-pod-with-team` (GPU pod with attribution).
- `policies/tests/tenancy-guard/` — `team-alpha/cd-pod-warm-floor-only`, `team-beta/training-pod-on-lendable` (correct pool placement).
- `policies/tests/deny-inline-secrets/` — `team-alpha/eso-managed-secret-team` (ESO-projected Secret).
- `policies/tests/eso-namespace-scope/` — `team-alpha/es-samens-store` (namespace-local SecretStore).
- `policies/tests/lendable-networkpolicy/` — generation of `default-deny-egress` for a training namespace (`generated-networkpolicy.yaml`).

### human-by-exception — merge gate (branch protection)
Prod topology/quota/NodePool edits are schema-valid (they would pass admission), so
the guard is **not** an admission policy — it is a required-review rule on the paths
that carry blast radius. The gate is technical: branch protection blocks merge until
an approving review lands. There is no admission fixture for this tier; it is proven
by repo settings (branch protection + path-scoped required reviewers), exercised in
U5's verification ("a NodePool edit is blocked pending review").

### never — admission policy (hard deny)
Cross-tenant references and inline secret material are refused at the API server, so
they can never reach a running cluster even if a merge slips through. These are the
`validationFailureAction: Enforce` Kyverno rules and the `Deny` VAP binding.

Proof fixtures (these evaluate to **fail** = admission deny):
- `policies/tests/eso-namespace-scope/` — `team-alpha/es-crossns-store` (SecretStore in another team's namespace) and `team-alpha/es-clusterstore-team` (ClusterSecretStore from a team namespace → foreign/prod secret path).
- `policies/tests/deny-inline-secrets/` — `team-alpha/inline-secret-team` (inline secret material).
- `policies/vap/deny-cross-namespace-refs.yaml` — pods that mount another team namespace's Secret/ConfigMap. **No kyverno CLI test** (CEL VAP evaluates only at cluster admission — see `policies/tests/README.md`).
- `policies/tests/tenancy-guard/` — `team-alpha/cd-pod-tolerates-lendable`, `team-beta/training-pod-tolerates-warm-floor` (R9 co-tenancy violations, denied at admission).
- `policies/tests/require-team-label/` — `team-alpha/gpu-pod-no-team` (unattributed GPU pod, denied).

## Notes

- **Identity (R5):** humans and agents are distinct, attributable principals. An
  agent-authored, namespace-scoped, non-prod change auto-passes the autonomous
  gate; a human-by-exception change requires a *human* approving review. Attribution
  on GPU workloads is enforced by `require-team-label` so GPU-hours resolve to a team
  (R6).
- **Secret paths are namespace-scoped (R13):** teams reference a namespace-local
  `SecretStore`; only platform namespaces may reference a cluster-wide
  `ClusterSecretStore`. Backend IAM confines which paths each store can read.
