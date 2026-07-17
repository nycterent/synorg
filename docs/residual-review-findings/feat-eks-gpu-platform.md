# Residual Review Findings — feat/eks-gpu-platform

Advisory / design-level findings from the multi-agent code review (2026-07-17)
that were **not** code-fixed this pass because they need human judgment, a live
cluster, or a decision the plan defers. The 2 P0s and 12 actionable findings
were applied in commit `fix(review): resolve 2 P0 admission cascades…`. These
remain open.

## Design decisions (owner: human)

- **Numeric cpu/memory now hard-errors, but ECS-unit semantics are unmapped.** `bridge.py` rejects bare-numeric cpu/memory; it does not *translate* ECS units (cpu 1024 = 1 vCPU) to K8s quantities. Decide whether the bridge should translate or require hand-authored quantities per service. (adversarial, correctness)
- **Multi-worker torchrun has no rendezvous Service.** `charts/training-job` renders no headless Service or `--rdzv-endpoint`; `workers > 1` never forms a group. Either add the Service+subdomain wiring or cap workers at 1 in the schema until multi-node is in scope. (correctness)
- **ApplicationSet vs service-values wiring.** `clusters/mgmt/appsets/regions.yaml` points a directory generator at `clusters/pilot/services/`, but those files are golden-chart *values*, not manifests — no `source.chart` + `helm.valueFiles` wiring exists, so a merged PR may not converge. Resolve the GitOps rendering path before the first real service migration. (agent-native)
- **`docs/agent-interface.md` observe-step gap.** The SLO read-API is named but no endpoint/auth/network path is documented outside `runbooks/game-day.md`. Surface the Prometheus access pattern in the canonical contract doc. (agent-native)
- **capability-tiers are prose-only.** No machine-checkable classifier or merge automation (CODEOWNERS/branch-protection/Mergify) enforces the autonomous-vs-human lane; the "auto-merge" claim is aspirational until wired. (agent-native, security)

## Residual risks (owner: human / release — surfaced, not blocking)

- **Label-trust dependency.** tenancy-guard and require-team-label key on self-declared pod labels; a `spec.nodeName`-pinned pod bypasses scheduler taint enforcement entirely. Mitigate with NodeRestriction admission + RBAC on `nodes`/`pods/binding`. (security, adversarial)
- **lending-controller RBAC breadth.** The controller SA can patch all Nodes, delete nodeclaims, evict pods, and patch ClusterQueue quota fleet-wide; a compromised SA could drain/delete the GPU fleet. Scope with per-pool label selectors if the API allows, and alert on controller-originated deletes. (security)
- **ODCR `instance_match_criteria = open`.** Open matching lets unrelated same-type/AZ launches consume freed held capacity during the ECS→EKS carve. Verify association by instance-id set, then flip to targeted matching post-capture. `prevent_destroy` was added this pass; the open-matching window remains. (adversarial)
- **borrowingLimit time-resolution + DST.** The schedule curve's wrap/DST semantics live only in comments; a naive time-of-day resolver yields 0% borrow between the last step and midnight. Encode the wrap rule in the controller, not prose. (adversarial residual)
- **Reserved-capacity feature dependency.** `capacity-type: reserved` NodePools silently fall back to on-demand if Karpenter's ReservedCapacity feature is not enabled in the pinned install — verify at bootstrap. (adversarial residual)
- **Cross-file placeholder invariants are hand-synced.** balloon `replicas` × per-node GPUs must equal the warm-floor size must equal the ODCR count; `platform-lendable` nominalQuota must equal the lendable NodePool limit. Nothing checks these. A cross-file invariant test would catch drift. (adversarial)
- **Doc-sync traps.** `docs/slo-catalog.md`↔`slo-definitions.yaml` and chart README↔`values.schema.json` are hand-mirrored with no CI diff gate; the checkpoint.dir drift fixed this pass was one instance. Consider a generator + drift check. (maintainability)

## Deferred to a live cluster

Kyverno VAP CEL rules, DCGM/kube-state-metrics label allow-lists, promtool rule
evaluation against real series, and every runbook's `kubectl` steps can only be
exercised once the pilot cluster exists (U3). The offline loop (`make validate`
+ policy composition + pytest) is the ceiling until then.
