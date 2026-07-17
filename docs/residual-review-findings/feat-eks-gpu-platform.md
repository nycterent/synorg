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

- ~~**#9 P1 `scripts/lib/ledger.sh:36` — zero-net-release guard vacuously green when terraform outputs unreadable.**~~ RESOLVED (2026-07-17): ledger_read now hard-fails on a nonzero `terraform output` via a new `ledger_fail_output` hook (per-caller wording in deploy.sh + run.sh, naming the chdir and the backend/init hint); only a SUCCESSFUL output returning an empty map still counts as "no reservations declared". run.sh's entry snapshot now runs `terraform -chdir=$ODCR_DIR init` first, so a missing backend fails at entry, never as a vacuous "none" sentinel.
- ~~**#10 P1 `tests/e2e/run.sh:247` — phase_down masks failed destroys.**~~ RESOLVED (2026-07-17): phase_down is errexit-independent — per-module `init && destroy` tracked with `rc=1` on failure (loop continues so everything destroyable is destroyed), DOWN OK printed only when rc=0, `return $rc`; on_exit's manual-cleanup branch now fires on any failed destroy.
- ~~**#5 P1 `.github/workflows/e2e.yaml` — CI cancellation/timeout kills the teardown trap mid-destroy.**~~ RESOLVED (2026-07-17): the job is split into --check / --up / --test / --down steps; the down step is `if: always() && !(inputs.keep-on-failure && steps.test.outcome == 'failure')` with its own `timeout-minutes: 60`, so cancellation of up/test cannot kill a destroy. The ledger entry snapshot moved into --up (idempotent guard) and the exit assert stays in --down, so the invariant spans the job; the single-shot full cycle is unchanged for manual use.
- ~~**#14 P2 `tests/e2e/assertions.sh:70` — port-forwards nonexistent `svc/prometheus`.**~~ RESOLVED (2026-07-17): prom_start resolves E2E_PROM override → any :9090 Service in the observability namespace (smoke.sh:270 jq discovery; E2E_PROM_NAMESPACE overrides) → `prometheus-operated` → loud FAIL naming the namespace. E2E_PROM documented in runbooks/e2e-gpu-run.md Variables.
- ~~**#15 P2 `tests/e2e/assertions.sh:341` — prom port-forward leaks when readiness times out.**~~ RESOLVED (2026-07-17): prom_start calls prom_stop (idempotent: unset/dead PID is a no-op) before returning nonzero on readiness timeout, and e2e_assert_all's early-return path runs the full cleanup (including prom_stop).
- ~~**#16 P2 `tests/e2e/assertions.sh:341` — kill during --test leaves the compressed rehearsal schedule live.**~~ RESOLVED (2026-07-17): e2e_assert_all installs a once-guarded cleanup (loadgen_stop; training_delete; restore_schedule; prom_stop) as EXIT/INT/TERM traps at entry, chaining any pre-existing handlers captured via `trap -p` (file redirect, no subshell) so run.sh's on_exit still fires with the original $? re-armed; traps are restored to the captured originals on completion. Chaining proven offline (mid-run kill → cleanup once + outer trap fires; normal completion → cleanup once + outer trap restored).

## Validated, unapplied — deployment hardening

- ~~**#6 P1 `clusters/pilot/lending/lending-controller.yaml:178` — bare Docker Hub image ref on the EKS-facing manifest.**~~ RESOLVED (2026-07-18): image is now `registry.synorg.io/platform/lending-controller:0.1.0` (org registry convention, platform domain); Dockerfile + README build/kind-load commands use the same tag, so the kind path loads exactly what the manifest references. Digest pinning is deferred until the first image is pushed (no real image exists yet) — noted in the manifest comment.
- ~~**#8 P1 `controllers/lending/reconcile.sh` kc() — no `--request-timeout`; a stalled API server wedges the tick loop forever (and there is no liveness probe to recover it).**~~ RESOLVED (2026-07-18): `kc()` now passes `--request-timeout=30s` (sibling smoke.sh/test.sh convention). Drain's long waits span many short requests (eviction creates + polls), so no call site depends on a single long request; RBAC/offline suite stays green.
- ~~**#13 P2 `controllers/lending/test.sh:227` — ORIG_LIMIT captured after scenarios 4a/4b already patched the ClusterQueue**, so the trap restore (applied as #11) writes back a test-mutated value on real clusters.~~ RESOLVED (2026-07-18): ORIG_LIMIT + BORROW_PATH are snapshotted once at live-tier entry, before the first reconcile tick; scenario 5 and the EXIT-trap restore both consume that pristine snapshot, and the queue-absent skip/no-op behavior is preserved.
- ~~**#17 P2 `.github/workflows/e2e.yaml:48` — `KUBECTL_VERSION: v1.31.0` drifts from the repo's k8s 1.33 convention** (integration.yaml v1.33.7, EKS cluster_version 1.33).~~ RESOLVED (2026-07-18): pinned to v1.33.7 with the integration.yaml-style one-line rationale comment.
- ~~**#18 P2 `clusters/pilot/lending/lending-controller.yaml` — no liveness probe on the controller Deployment.**~~ RESOLVED (2026-07-18): reconcile.sh writes `$KUBECTL_CACHE_DIR/heartbeat` at startup and after every tick (loop-alive semantics — including schedule_invalid skips and handled failures); the Deployment gains an exec livenessProbe asserting heartbeat mtime < 300s (5 missed ticks at TICK_SECONDS=60; initialDelay 90s, period 60s, failureThreshold 3). README documents the loop-alive-not-tick-success contract.

## Advisory (owner: human — e2e assertion strength)

- **#19 P2 `tests/e2e/assertions.sh:208` — assert_reclaim can pass via close-time untaint, not actual reclaim** (driven closesAt +11m clears taints before the +15m ramp deadline regardless of drain). Require reclaim evidence (events / deleted NodeClaims) or move closesAt past the deadline. (adversarial)
- **#20 P2 `tests/e2e/assertions.sh:224` — scrub "new instance" proof satisfied by any second pool node.** Snapshot all pool providerIDs at lend time; require one outside the entry set. (adversarial)

## Suppressed at gate (anchor 50 — noted for completeness)

- Makefile integration loop would pass green if `find` matched nothing (partially mitigated: the lending suite now runs unconditionally). Consider an empty-set guard (R6).
- reconcile.sh borrowingLimit JSON patch uses `replace`; `add` also creates the field when absent.

---

# First live integration run — findings fixed (2026-07-18, mini/colima)

`make integration` now passes CLEAN-SLATE on a real kind cluster (colima on
mini): lending controller suite ALL CHECKS PASSED (incl. the #3/#7 live
scenarios), admission 10/10, scheduling 5 passed / 2 loud-skips (kwok absent
under SKIP_KWOK=1; TAS out-of-scope) / 0 failed, teardown clean. Two REAL
product defects and two harness gaps were caught live and fixed:

- **VAP CEL `flatten()` does not exist in the k8s CEL environment** (through
  1.33) — `deny-cross-namespace-refs` never compiled on a real API server;
  exactly the offline blind spot the plan named. Rewritten as a nested
  `.all(l, l.all(n, ...))` over the list-of-lists (semantically identical).
- **`training-borrow` ClusterQueue covered only `nvidia.com/gpu`** — Kueue
  refuses admission for any pod requesting uncovered resources ("resource cpu
  unavailable in ClusterQueue"); NO training job could ever admit, on kind or
  the real pilot. Added generous non-constraining cpu/memory quotas (GPU stays
  the only constraining resource). Kueue webhook also requires `resources[]`
  order to mirror `coveredResources[]`.
- fake-gpu-operator 0.0.70's compute-domain DeviceClass template renders
  unconditionally and needs a served `resource.k8s.io` API → kind cluster now
  enables the DRA beta gate (harness-side only). The `--fallback` status-patch
  path proved scheduling-only (kubelet device-plugin admission blocks the probe
  pod) — verify.sh caught it as designed.
- scheduling_test.sh's borrowingLimit read/patch was index-based
  (`resources[0]`) and broke when cpu/memory coverage landed — now name-keyed
  like the controller's own path-finder.
