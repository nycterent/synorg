# Residual Review Findings — feat/eks-gpu-platform

Advisory / design-level findings from the multi-agent code review (2026-07-17)
that were **not** code-fixed this pass because they need human judgment, a live
cluster, or a decision the plan defers. The 2 P0s and 12 actionable findings
were applied in commit `fix(review): resolve 2 P0 admission cascades…`. These
remain open.

## Design decisions (owner: human)

- **Numeric cpu/memory now hard-errors, but ECS-unit semantics are unmapped.** `bridge.py` rejects bare-numeric cpu/memory; it does not *translate* ECS units (cpu 1024 = 1 vCPU) to K8s quantities. Decide whether the bridge should translate or require hand-authored quantities per service. (adversarial, correctness)
- **Multi-worker torchrun has no rendezvous Service.** `charts/training-job` renders no headless Service or `--rdzv-endpoint`; `workers > 1` never forms a group. Either add the Service+subdomain wiring or cap workers at 1 in the schema until multi-node is in scope. (correctness)
- ~~**ApplicationSet vs service-values wiring.**~~ RESOLVED (2026-07-17): `regions.yaml` now excludes `services/`, and `clusters/mgmt/appsets/services.yaml` renders each values file through `charts/golden-service` via a git file generator + multi-source Helm app (`$values` ref). Wiring correctness is cluster-verifiable only; YAML + golden-chart render are green offline. (agent-native)
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

---

# Residual Review Findings — walking-skeleton run (plan 002, 2026-07-17)

Source: multi-agent review run `20260717-223549-b3a65f83` (9 personas + 15
independent validators; 15/15 findings validated true, 0 false positives).
Applied this pass in `fix(review)`: #1 (P0 team-label on scheduling fixtures),
#2 (test.sh wired into make integration), #4 (test.sh context pinning),
#11 (borrowingLimit trap restore). No sink available (repo has no remote /
tracker) — this file is the durable record. Full artifacts:
`/tmp/compound-engineering/ce-code-review/20260717-223549-b3a65f83/`.

## Validated, unapplied — controller reclaim lifecycle (decision-gate, do first)

- ~~**#3 P1 `controllers/lending/reconcile.sh:301` — close-time untaint starves the final reclaim wave; nodes return unscrubbed.**~~ RESOLVED (2026-07-17): tick() reordered to waves-before-taints, and the close transition now routes every still-lent node through the shared `reclaim_node` path (EKS cordon+drain+NodeClaim delete; loud-warn + untaint when no NodeClaim; kind `reclaim_intent reason=window_close` + untaint) — never a bare untaint.
- ~~**#7 P1 `controllers/lending/reconcile.sh:247` — waves re-fire every tick within the 300s window, compounding ceil(fraction x currently-lent) toward 1-(1-f)^5 (~97% for f=0.5).**~~ RESOLVED (2026-07-17): fired-wave marker files under `KUBECTL_CACHE_DIR/fired-waves/` (once per wave per local day, pruned after 2 days; emptyDir restart caveat documented) plus a structural backstop — wave and close-path selection excludes already-cordoned nodes.
- ~~**#12 P2 `controllers/lending/reconcile.sh:99` — malformed schedule time reads as window-closed: mass untaint without drain.**~~ RESOLVED (2026-07-17): validate_schedule now regex-gates every clock field (window opensAt/closesAt, reclaimWaves[].startsAt, borrowingLimitCurve[].at against strict HH:MM) and every days[] name; any failure logs schedule_invalid and skips the whole tick before any kubectl call, with offline malformed-time/day fixtures asserting zero actuation.

These three shared one root cause (wave lifecycle had no once-semantics, wrong
ordering, weak validation) — redesigned once, closed together (2026-07-17).

## Validated, unapplied — e2e teardown and evidence integrity

- **#9 P1 `scripts/lib/ledger.sh:36` — zero-net-release guard vacuously green when terraform outputs unreadable.** `output ... || echo '{}'` makes failure indistinguishable from empty; CI without backend.tf always reads the "none" sentinel at entry AND exit, so the never-release-capacity invariant passes vacuously (violates plan R6). Fix: hard-fail on terraform-output error; snapshot after ODCR init. (adversarial; validated)
- **#10 P1 `tests/e2e/run.sh:247` — phase_down masks failed destroys.** `phase_down || {...}` disables errexit inside the function (empirically verified); a failed mid-loop terraform destroy still prints DOWN OK and returns 0. Fix: per-module `|| rc=1`, return rc. (adversarial; validated)
- **#5 P1 `.github/workflows/e2e.yaml` — CI cancellation/timeout kills the teardown trap mid-destroy.** Single run step carries deploy+test+teardown; GitHub kill grace is seconds vs minutes of destroy. Fix: split steps, `if: always()` down step with own timeout; consider janitor workflow. (adversarial; validated)
- **#14 P2 `tests/e2e/assertions.sh:70` — port-forwards nonexistent `svc/prometheus`.** kube-prometheus-stack creates `<release>-kube-prometheus-prometheus` / `prometheus-operated`. Fix: discover by port 9090 like smoke.sh:270; document E2E_PROM in the runsheet. (correctness; validated)
- **#15 P2 `tests/e2e/assertions.sh:341` — prom port-forward leaks when readiness times out.** prom_start returns 1 without killing its spawned process; early return skips prom_stop. (reliability; validated)
- **#16 P2 `tests/e2e/assertions.sh:341` — kill during --test leaves the compressed rehearsal schedule live.** Demoted from P1: ArgoCD selfHeal reverts the ConfigMap; loadgen + training workload are NOT ArgoCD-managed and still need a trap. Fix: trap-based cleanup around the assertion loop. (adversarial; validated, severity demoted by validator)

## Validated, unapplied — deployment hardening

- **#6 P1 `clusters/pilot/lending/lending-controller.yaml:178` — bare Docker Hub image ref on the EKS-facing manifest.** `synorg/lending-controller:0.1.0` pulls docker.io on EKS; sibling workloads use `registry.synorg.io/*`. Fix: private registry + digest for EKS; bare tag only for kind-load. (security; validated)
- **#8 P1 `controllers/lending/reconcile.sh` kc() — no `--request-timeout`; a stalled API server wedges the tick loop forever (and there is no liveness probe to recover it).** Fix: `--request-timeout=30s` in kc(). One line. (reliability; validated)
- **#13 P2 `controllers/lending/test.sh:227` — ORIG_LIMIT captured after scenarios 4a/4b already patched the ClusterQueue**, so the trap restore (applied as #11) writes back a test-mutated value on real clusters. Fix: snapshot before the first live tick. (correctness; validated)
- **#17 P2 `.github/workflows/e2e.yaml:48` — `KUBECTL_VERSION: v1.31.0` drifts from the repo's k8s 1.33 convention** (integration.yaml v1.33.7, EKS cluster_version 1.33). One line. (maintainability; unvalidated — over validation budget)
- **#18 P2 `clusters/pilot/lending/lending-controller.yaml` — no liveness probe on the controller Deployment.** Fix: per-tick heartbeat file + exec probe. (reliability; unvalidated — over validation budget)

## Advisory (owner: human — e2e assertion strength)

- **#19 P2 `tests/e2e/assertions.sh:208` — assert_reclaim can pass via close-time untaint, not actual reclaim** (driven closesAt +11m clears taints before the +15m ramp deadline regardless of drain). Require reclaim evidence (events / deleted NodeClaims) or move closesAt past the deadline. (adversarial)
- **#20 P2 `tests/e2e/assertions.sh:224` — scrub "new instance" proof satisfied by any second pool node.** Snapshot all pool providerIDs at lend time; require one outside the entry set. (adversarial)

## Suppressed at gate (anchor 50 — noted for completeness)

- Makefile integration loop would pass green if `find` matched nothing (partially mitigated: the lending suite now runs unconditionally). Consider an empty-set guard (R6).
- reconcile.sh borrowingLimit JSON patch uses `replace`; `add` also creates the field when absent.
