# Infra audit — SRS design lens (2026-07-20)

Read-only design audit of the synorg infra as committed, through the eight lenses
of Google's *Building Secure and Reliable Systems* (least privilege,
understandability, changing landscape, resilience, recovery, DoS, supply chain,
crisis & culture). Findings are grounded in `file:line` and ranked by **blast
radius × likelihood**. Three parallel auditors covered identity/tenancy/supply-chain,
the lending control loop (`reconcile.sh`), and terraform/recovery/crisis.

Scope caveat: cluster RBAC bindings, live GitHub repo settings, and running
secrets were out of scope. Where a claim depends on them, it's flagged.

---

## The headline: the tiered-governance model is convention, not enforcement

Four findings interlock into one meta-finding that dominates the audit. The
`capability-tiers.md` model promises three tiers — *denied at admission*,
*human-by-exception*, *autonomous* — enforced so "none can be merged around."
In the committed repo, **the gate between a PR (human or agent) and a fleet-wide
reconcile is not actually enforced for the two upper tiers:**

- **`capability-tiers.md:24,42-48` claims a "technical gate … proven by repo
  settings (branch protection + path-scoped required reviewers)."** Path-scoped
  required reviewers need a **CODEOWNERS file — there is none** (`find` returns
  nothing; `.github/` holds only workflows), and no ruleset is checked in. The
  load-bearing control for the highest-blast-radius tier (prod topology, quota,
  NodePool changes) is an unversioned, unproven GitHub setting.
- **All five ApplicationSets run `project: default`** (`clusters/mgmt/appsets/regions.yaml:57`,
  `services.yaml:45`, `training-runs.yaml:50`, `observability.yaml:37,109`). The
  built-in `default` AppProject permits all repos, all destinations (`namespace:'*'`,
  `server:'*'`), all resources. The one scoped project (`appproject-example.yaml`)
  is referenced by nothing. Destination namespaces are templated from untrusted
  file content, so a values file naming `kube-system` deploys there unopposed.
- **All AppSets track `HEAD` with `selfHeal:true` + `prune:true`** — a merge on
  the default branch reconciles fleet-wide automatically, with no signed-tag or
  commit-digest pin and no admission-time provenance check.
- **The lending schedule (`schedule.yaml`) — "the ONLY write path" for
  lend/reclaim — rides the same auto-approval lane** (the evidence plane targets
  80% auto-approve, `recording-rules.yaml:114-122`), and `validate_schedule` never
  asserts the pool it aims is actually the lendable pool (see P0-2).

Together: the autonomous and by-exception tiers are a *naming convention over the
change*, not a control that holds when the change is hostile or wrong. Fixing any
one leaves the hole open; they must be closed together — commit CODEOWNERS + the
branch-protection ruleset as code, bind each Application to a per-team AppProject,
and pin `targetRevision` to gated release tags.

---

## P0 — fix before production / before a second tenant

### P0-1 · Tiered governance is unenforced (the meta-finding above)
Blast: **fleet** · Likelihood: **med**. Refs above.

### P0-2 · The warm floor is one auto-approvable typo from deletion
`clusters/pilot/lending/lending-controller.yaml:61-70`, `reconcile.sh:306,375,520`,
`schedule.yaml:43` · Blast: **fleet (the inference SLO floor itself)** ·
Likelihood: **low, consequence catastrophic**.
The controller ClusterRole grants `nodes` patch/update and `nodeclaims` delete
**cluster-wide, unrestricted**. The only thing keeping the full cordon/drain/
delete-NodeClaim machinery off the never-lent warm floor is a code selector
`karpenter.sh/nodepool=$pool`, where `pool` is read straight from the schedule.
Warm floor and lendable differ only by label/taint (same EC2NodeClass, instance
types, ODCR pool). A schedule with `lendablePool: gpu-warm-floor` would drain and
delete the inference floor — and the floor's `budgets: nodes:"0"` + balloon only
stop *Karpenter* consolidation, not an external NodeClaim delete. `validate_schedule`
never checks this. **Fix: pin the selector to a constant or assert
`lendablePool != gpu-warm-floor`, and require human review on `schedule.yaml`.**

### P0-3 · A crash mid-reclaim strands a lent node that both paths then skip
`controllers/lending/reconcile.sh:274-283, 330-331, 521, 517` · Blast:
**pool + workload** · Likelihood: **med**.
`reclaim_node` cordons → drains (up to 360s) → deletes the NodeClaim —
non-atomic. The idempotency guard that makes re-fires safe (`skip cordoned =
"in-flight reclaim"`) is also the trap: if the pod dies during the ~360s drain
(OOM, deploy rollover, node loss), the node returns **cordoned + still lent +
still running training**, and no reconciler resumes it — both paths treat it as
"someone else's." It sits lent past the ramp; only the warm floor saves inference.
**Fix: on each tick, actively re-drive cordoned-lent nodes to completion;
distinguish "live in-flight reclaim" from "abandoned" via a timestamp/annotation.**

### P0-4 · Is the code that runs the code you reviewed? — No.
`charts/training-job/templates/job.yaml:60`, `capability-tiers.md:23`, ADR 0007:16-24,
`clusters/mgmt/appsets/observability.yaml:43,113` · Blast: **region / fleet** ·
Likelihood: **med**.
Workloads resolve as `repository:tag` — a **mutable tag** an agent supplies in a
values file; images are public on ghcr, pulled without auth, with **no cosign /
binary-authorization admission check** anywhere in `policies/`. A "values-only
prod image bump" sits in the **autonomous (auto-merge, no human)** lane. Third-party
Helm charts install fleet-wide on floating minor ranges (`kube-prometheus-stack
65.x`, `dcgm-exporter 3.x` — the file's own TODO admits it). The ghcr push
credential is a **classic PAT with `write:packages`** (ADR 0007:23-24) — long-lived,
can overwrite any tag. **Fix: require digest-pinned images from the canonical
registry via admission policy; verify provenance (cosign) at deploy; pin the
charts; replace the PAT with OIDC/fine-grained token.**

---

## P1 — serious, fix soon

### P1-1 · No fast, governed kill switch; the only in-band "stop" is a storm
`schedule.yaml:1-8`, `reconcile.sh:318-344` · Blast: **fleet** · Likelihood: **med**.
No `lendingEnabled:false` flag, no break-glass. To stop lending under incident you
open a PR (CI + merge + sync — not seconds) or scale the Deployment to 0 (which
*freezes* recovery state). Narrowing the window to force a stop calls `reclaim_node`
on **every** still-lent node in one tick with no `reclaimFraction` staging — the
`storm-all-at-once` case, survived only because the warm floor backstops it.
**Fix: a controller-honored pause flag that halts actuation without freezing
recovery, plus a documented emergency abort.**

### P1-2 · Kyverno `Enforce` gates all pods fleet-wide with no break-glass
`policies/kyverno/tenancy-guard.yaml:16`, `require-team-label.yaml:14`,
`deny-inline-secrets.yaml:16` · Blast: **fleet** · Likelihood: **low-med
(outage-triggered)**.
These match every Pod at `validationFailureAction: Enforce` via the Kyverno
webhook (default `failurePolicy: Fail`). A Kyverno outage fails closed and blocks
*all* pod creation fleet-wide — no cached fallback or documented bypass exists.
(Contrast the in-process VAP, which is materially safer — see Clean.) **Fix:
document a scoped `failurePolicy` carve-out / webhook-bypass runbook and alert on
Kyverno availability.**

### P1-3 · Live ODCR apply runs on local terraform state
`runbooks/deploy-platform.md:57`, contra `infra/terraform/backend.tf.example:39-41`
· Blast: **region + state trust-root** · Likelihood: **med**.
The bootstrap for the single most irreversible module runs `terraform init
-backend=false` (comment says "wire real backend for a live apply" — the flag does
the opposite), so the apply that creates `prevent_destroy` + `unlimited`-duration
held reservations writes **local** state — no lock, no versioning, no shared
truth. A lost state file orphans irreversible capacity. **Fix: init against the
real S3+Dynamo backend before any capacity-touching apply; delete the
`-backend=false` line.**

### P1-4 · No per-tenant Kueue quota — one team starves the borrow queue
`clusters/pilot/kueue/clusterqueue-training-borrow.yaml:41-60`,
`localqueue-team-example.yaml:26` · Blast: **workload (other training tenants)** ·
Likelihood: **med**.
Every team's LocalQueue forwards to one `training-borrow` ClusterQueue with a
single `borrowingLimit` and no per-team `nominalQuota`. Among equal-priority jobs
it's first-come — one team's wave starves the rest. Usage is *attributed* per team
but not *limited*. Acceptable at one pilot team; a gap the moment a second onboards
(ADR 0008 notes the design is intentional-but-conditional). **Fix: per-team quotas
within the cohort before the second tenant.**

### P1-5 · Liveness is loop-alive, not tick-success; a single replica can miss a wave silently
`lending-controller.yaml:169-171`, `reconcile.sh:584,507` · Blast: **pool** ·
Likelihood: **med**.
The heartbeat is touched after *every* tick including handled failures, so a
controller that is alive but failing every kubectl call (API down, RBAC revoked)
never trips liveness — it silently fails to reclaim during the morning window.
`replicas:1` + `Recreate` + no leader-elected standby, and the wave fire window
(300s) equals the liveness staleness threshold — a wedged controller can take
longer to be killed + rescheduled than the window, so a wave is missed outright.
**Fix: a tick-success signal wired to an alert; bring forward leader election.**

### P1-6 · Break-glass is pre-authorized but not audited
`runbooks/training-intake-break-glass.md:12-29`, `runbooks/operations.md:127,140`,
ADR 0004:16-21 · Blast: **fleet / region** · Likelihood: **med**.
The break-glass paths are well pre-authorized by condition and well-bounded, but
nothing on the path requires **recording the invocation** — no event, no ledger
row, no auto-opened review. `operations.md:140` itself notes hand-applying "breaks
audit," yet the sanctioned bypasses emit no record of who/when/why. Pre-authorized
without audited is half the control. **Fix: every break-glass action writes a
timestamped who/why/what record and auto-opens a review.**

### P1-7 · Suspected-compromise recovery destroys forensic evidence
`runbooks/operations.md:33,116-120` · Blast: **cloud-account** · Likelihood: **low**.
"Rebuild the hub from Terraform + git (it is fully reproducible)" is a fast, clean
*availability* recovery — but on a **security** incident it wipes the running
state needed to learn how the breach happened. No "preserve evidence before you
rebuild/rotate" step exists. **Fix: an evidence-preservation gate (snapshot EBS,
export audit logs, isolate) on the compromise path, distinct from the plain-outage
rebuild.**

### P1-8 · No incident-command structure or blameless posture defined
`runbooks/gpu-node-quarantine.md:91`, `node-scrub.md:111`, `capacity-carve.md:76`
· Blast: **org process** · Likelihood: **med**.
Four runbooks say "open an incident" but nothing defines **who runs it**: no
Incident Commander, no comms/scribe split, no severity ladder, no postmortem
template, no blameless framing. The game-day "signed-off report" is a gate
artifact, not a retrospective. **Fix: an incident-response runbook defining
IC/comms/scribe, escalation, and a blameless postmortem template.**

---

## P2 — hardening

- **P2-1 · Checkpoint store uses the AWS-managed KMS key with no bucket policy** —
  `checkpoint-store/main.tf:43-48`. `aws:kms` with no `kms_master_key_id` → the
  unscopable `aws/s3` managed key; access gated by IRSA only. Training state is an
  untrusted trust domain vs customer-data inference. Fix: customer-managed CMK with
  a key policy scoped to trainer IRSA + a deny-by-default bucket policy (TLS + CMK).
- **P2-2 · Training trainer container has no `securityContext` (may run as root) on
  shared lendable nodes** — `charts/training-job/templates/job.yaml:58-116`
  (contrast the hardened controller Dockerfile). Fix: hardened pod/container
  securityContext.
- **P2-3 · `lendable-networkpolicy` ships a `10.0.0.0/8` egress allow placeholder**
  — `policies/kyverno/lendable-networkpolicy.yaml:56-61`. If an overlay forgets to
  pin the CIDR, training pods reach all of RFC1918. Fix: leave it unset/invalid so
  it fails loudly, or template as a required overlay value.
- **P2-4 · "Reclaim beats the ramp" is schedule-authored, not code-enforced** —
  `README.md:81-83`, `schedule.yaml:36`. `productionRampAt` /
  `nodeReturnToServiceBudgetSeconds` are read-only in v0; the 30-min margin is a
  human constant. Fix: compute wave lead time from the return budget vs ramp; alert
  if remaining-lent × return-budget won't clear.
- **P2-5 · CI `validate`/`integration`/`nightly` set no `permissions:` block and
  fetch toolchains without checksum; actions pinned to mutable major tags** —
  contrast the model `e2e.yaml`. Fix: `permissions: contents: read`, verify tool
  sha256, pin actions to SHAs.
- **P2-6 · Spoke API server default admits the whole VPC `/16`** —
  `regions/pilot/main.tf:29-38`, `variables.tf:85-89`. `hub_ingress_cidr` defaults
  to `10.42.0.0/16`. Fix: make it required (no default) so a prod apply must state
  the real narrow CIDR.
- **P2-7 · Node AMI pinned to `al2023@latest`** — `ec2nodeclass-gpu-held.yaml:14-15`.
  Scrubbed nodes reboot on a moving target on the reclaim critical path. Fix: pin to
  a digest/version (comment already plans it).
- **P2-8 · Inference HPA scales on CPU only for a GPU service; no app-layer
  shedding** — `charts/golden-service/templates/hpa.yaml:16-21`. Fix: scale on a
  GPU/latency metric; add request-level shedding at the inference gateway.
- **P2-9 · Two tenancy policies overclaim what they enforce** —
  `eso-namespace-scope.yaml:65-68` checks `store.name == namespace` (over-denies
  valid names, doesn't verify ownership); `deny-cross-namespace-refs.yaml:42-56` is
  a naming lint, not the cross-tenant secret control the docs imply (k8s already
  resolves secret refs namespace-locally). Fine as defense-in-depth; relabel the
  docs so the stated invariant matches the CEL.
- **P2-10 · Checkpoint lifecycle omits incomplete-multipart-upload cleanup** —
  `checkpoint-store/main.tf:63-76`. Multi-GB shards killed mid-flush bill
  indefinitely. Fix: `abort_incomplete_multipart_upload { days_after_initiation = 1 }`.
- **P2-11 · Terraform state-bucket write access is unscoped in the shipped config**
  — `backend.tf.example:24-45`. State is the trust root; the example sets
  encrypt+lock+versioning but no bucket policy / MFA-delete / least-privilege deploy
  role. Fix: ship a state-bucket policy + role guidance alongside the example.

---

## Checked and clean (what's genuinely solid)

The audit found real strength — this is a well-built skeleton, not a shaky one:

- **Staged reclaim with non-compounding once-semantics is real** — waves at
  0.25/0.50/1.0, the fired-marker keys on date+index+startsAt so game-day re-drives
  re-fire correctly, and selection excludes already-cordoned nodes as a structural
  backstop (`reconcile.sh:515-521,474-484`). Genuinely prevents `1-(1-f)^n`.
- **Malformed schedule fails closed before any kubectl** — `validate_schedule`
  gates schema/fields/`HH:MM`/day-names; `test.sh:217-235` asserts no action line
  ever appears on garbage input. The `valid_hm` gate specifically kills the
  "arithmetic-error-reads-as-window-closed" mass-untaint bug.
- **Inference/training isolation is strong and one-directional** — inference never
  enters Kueue and preempts via PriorityClass 1000000; `training-preemptible` is
  `preemptionPolicy: Never`; training tolerates only lendable taints, never
  warm-floor; warm-floor balloon + `budgets: nodes:"0"` hold the floor against
  consolidation.
- **The offline RBAC-subset proof** — `test.sh:55-170` parses every kubectl call,
  maps it to (group,resource,verb), and fails closed on anything the ClusterRole
  doesn't grant — a real least-privilege proof runnable without a cluster. The role
  deliberately grants no NodePool/EC2NodeClass verbs (prevents whole-pool-replacement
  drift).
- **The in-cluster-config blind-spot is found and fixed in code** —
  `materialize_incluster_kubeconfig` documents a live EKS failure (a
  `--request-timeout` disabling kubectl's in-cluster fallback → controller went
  blind) and every request is bounded by `--request-timeout=30s`.
- **`e2e.yaml` is a model least-privilege CI surface** — `workflow_dispatch` only,
  double-confirm gate, OIDC (no static keys), an assume-role that explicitly
  *excludes* `ec2:CancelCapacityReservation`, teardown in `always()`. `validate.yaml`
  uses `pull_request` (not `pull_request_target`) so fork code never runs with
  secrets.
- **ArgoCD hub hardened** — `exec.enabled:false`, `server.insecure:false`, Dex
  disabled, `Prune=false` so a bad sync can't self-delete the hub. Controller image
  digest-pinned.
- **The `deny-cross-namespace-refs` VAP is an in-process, network-independent
  fail-closed** — materially safer than the Kyverno webhook (only a CEL bug, not an
  outage, can trip it).
- **ODCR blast-radius discipline is excellent** — `prevent_destroy` on held
  reservations, positive-count validation, a verify-before-terminate gate enforced
  one-instance-per-invocation. The one source-tree IAM `"*"` is on
  `ec2:DescribeCapacityReservations` (which AWS can't scope); the consumption
  actions are ARN-scoped. No hardcoded secrets/account-IDs/ARNs in source. Providers
  hash-locked in all four roots. State backend example is encrypt+lock+versioned.
- **game-day is a real rehearsal** — real preemption, repeat-runs before any
  verdict, abort-on-unmeasurable-evidence, cross-run variance gate. The strangler
  migration is incremental with a cheap weight-flip rollback.

---

## Security × reliability tradeoffs (named, per the SRS method)

- **Idempotency vs crash-resumption (the crown-jewel tension).** The "skip cordoned
  = in-flight reclaim" rule is what makes re-fires safe *and* what strands a node
  when the process dies mid-reclaim (P0-3). The design bought double-act safety at
  the cost of crash-resume safety; it needs both. The warm floor currently covers
  the gap.
- **GitOps integrity vs incident speed.** "Git is the ONLY write path" is a strong
  attribution property and the right default — but it removes the fast emergency
  lever, and the only in-band "stop" fires an un-staged storm (P1-1). Currently
  resolves entirely toward integrity; needs a governed-*and*-fast pause.
- **Scrub-safety vs availability, un-timed against the ramp.** The controller
  correctly parks an unscrubbable node rather than return training's VRAM residue to
  inference (isolation over availability) — but it does not *compute* whether reclaim
  beats the ramp (P2-4). The deadline the whole system exists to protect is
  warm-floor-backstopped, not actuator-guaranteed. Honest for a v0 skeleton.
- **Fail-closed admission vs availability.** Kyverno `Enforce` fleet-wide with no
  break-glass (P1-2) trades a tenancy breach (unrecoverable) against an outage
  (recoverable) — the right direction, but missing the cached-last-known-good /
  bypass that keeps an engine blip from becoming an outage.
- **Availability vs cost (handled).** ADR 0005 names the unlimited-duration ODCR
  hold as insurance and measures the premium first-class (`utilization-of-held`,
  `idle-burn`, 70% floor, quarterly review) — a clean, reasoned tradeoff.

---

*Method: `secure-reliable-systems` skill (SRS design lens). Three parallel
grounded auditors, findings ranked blast-radius × likelihood.*
