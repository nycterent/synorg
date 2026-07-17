# Policy plane (U5)

KTD8 hybrid: built-in **ValidatingAdmissionPolicy** (CEL) for stateless field
rules with no webhook latency; **Kyverno** ClusterPolicies for cross-resource
lookups, generation, and secret-material checks. All names follow
[`docs/conventions.md`](../docs/conventions.md); tier semantics are in
[`docs/capability-tiers.md`](../docs/capability-tiers.md).

## Layout

```
policies/
  kyverno/    ClusterPolicies (validationFailureAction: Enforce)
  vap/        ValidatingAdmissionPolicy + binding (CEL)
  tests/      kyverno test fixtures — one dir per policy
```

## Kyverno ClusterPolicies (`kyverno/`)

| File | Enforces | Requirement |
|---|---|---|
| `require-team-label.yaml` | GPU pods must carry `team.synorg.io/name`. | R6 (attribution) |
| `tenancy-guard.yaml` | customer-data pods never tolerate `pool.synorg.io/lendable`; training never tolerates `pool.synorg.io/warm-floor`. | R9 |
| `deny-inline-secrets.yaml` | Team-namespace Secrets carrying inline material are denied unless ESO-managed. | R13 (never tier) |
| `eso-namespace-scope.yaml` | ClusterSecretStore is platform-only; namespaced SecretStore refs stay in-namespace. | R13 |
| `lendable-networkpolicy.yaml` | **Generate:** training namespaces get a `default-deny-egress` NetworkPolicy (DNS + checkpoint-store CIDR only). | R9 (network isolation) |

## ValidatingAdmissionPolicy (`vap/`)

| File | Enforces | Requirement |
|---|---|---|
| `deny-cross-namespace-refs.yaml` | Pods may not mount a Secret/ConfigMap that names another team namespace. | R7 (never tier) |

> **VAP has no kyverno CLI test.** CEL ValidatingAdmissionPolicies evaluate only at
> cluster admission — there is no offline `kyverno test` equivalent, and
> `scripts/validate.sh` schema-checks them with kubeconform but cannot evaluate the
> CEL locally (see the loop limitation note in `docs/conventions.md`). Behavioral
> coverage lands with the policy fixtures once a cluster exists. The VAP is
> schema-valid offline and its CEL is written as a stateless field rule (namespace
> vs. team-prefixed reference name) with no cross-resource lookup.

## Running the tests

```bash
kyverno test policies/tests --detailed-results
```

Each `policies/tests/<policy>/` directory holds a `kyverno-test.yaml` plus resource
fixtures covering PASS and FAIL cases. A `pass`/`skip` result means the resource is
admitted (skip = out of the rule's scope); a `fail` result means the rule denies it
(or, for the generate rule, that the NetworkPolicy is produced). These fixtures are
the **local proof** of admission behavior — the policies exist and enforce only at a
live cluster; no cluster is exercised by the test suite.

Schema validation runs inside `make validate` (kubeconform against the Kubernetes
and datreeio CRDs schemas, `-ignore-missing-schemas` for CRDs not in the catalog).
