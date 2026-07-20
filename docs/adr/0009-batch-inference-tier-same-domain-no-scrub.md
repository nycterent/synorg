# ADR 0009 — Batch-inference tier: a third priority class, same trust domain, no scrub

- **Status:** proposed (grilling / value-case session, 2026-07-20). Prerequisite
  for the batch-inference recovery claimed in [docs/value-case.md](../value-case.md)
  §4. Not implemented; designed here.

- **Context:** The platform models **two** GPU workload classes today —
  `inference-critical` (value 1000000, PreemptLowerPriority) and
  `training-preemptible` (value 1000, Never-preempt) in
  [clusters/pilot/kueue/priorityclasses.yaml](../../clusters/pilot/kueue/priorityclasses.yaml).
  That binary hides a third class the internal B2B customer actually runs: **batch
  inference** (async generation — text-to-video and similar). It differs from the
  two existing classes on two axes that do not move together:

  - **SLA hardness.** Batch inference is soft-SLA (a deadline in minutes to hours),
    so unlike realtime it *can* be queued and preempted. This is what makes it a
    filler for idle capacity.
  - **Trust domain.** Batch inference serves the same customer data as realtime
    inference, so it is the **same trust domain**. A node handed from realtime to
    batch inference and back needs **no scrub** — the R9/R12 tenancy boundary that
    forces the scrub on R&D training does not exist here.

  The no-scrub property is the whole point. Because batch inference yields a node
  with a fast checkpoint-and-requeue rather than the slow, scrub-bounded drain
  training needs, it can safely soak capacity that training cannot: daytime realtime
  troughs, and the warm floor itself. It also refines **KTD6** ("serving is never
  Kueue-admitted"): that rule holds for *realtime* serving, whose render path must
  never queue. Batch inference is the first inference class that *is*
  Kueue-admitted, precisely because it is allowed to wait.

- **Decision:** Introduce a batch-inference tier between the two existing classes,
  and let it use capacity by its trust domain, not just the lendable pool.

  1. **New `PriorityClass batch-inference`, value 100000, `preemptionPolicy:
     PreemptLowerPriority`.** It sits below `inference-critical` (1000000) and above
     `training-preemptible` (1000). Ordering on any shared node is therefore
     realtime → batch inference → training: realtime preempts batch inference,
     batch inference preempts training, training preempts nothing.

  2. **New `ClusterQueue batch-inference-borrow` in the `gpu-lending` cohort**,
     nominal `nvidia.com/gpu` quota 0, borrowing the lendable pool from
     `platform-lendable` — the same borrowing shape as `training-borrow`, but
     admitted at higher workload priority so batch inference wins scarce lendable
     GPUs over training within the cohort.

  3. **Batch inference may reference both the `gpu-lendable` and `gpu-warm-floor`
     ResourceFlavors; training stays lendable-only.** This is the load-bearing
     departure from training's R12 containment. Because batch inference is the
     realtime trust domain and yields instantly to `inference-critical` via
     kube-scheduler preemption, it can backfill warm-floor troughs *without*
     compromising the floor's insurance role — realtime reclaims its GPU in
     milliseconds, no scrub, no drain. Training can never do this (cross-domain,
     scrub-bounded), which is why lending the warm floor to *training* is a P0 risk
     (see the infra audit, warm-floor-deletion finding) while backfilling it with
     *batch inference* is safe.

  4. **Batch-inference reclaim does not go through the lending controller's node
     lifecycle and never triggers a scrub.** Returning a node from batch inference
     to realtime is pure kube-scheduler preemption plus Kueue `borrowingLimit`; the
     node never leaves the inference trust domain, so there is nothing to scrub. The
     controller's scrub-on-return and staged drain waves remain training-only.

- **Design (concrete):**

  ```yaml
  # priorityclasses.yaml — add:
  apiVersion: scheduling.k8s.io/v1
  kind: PriorityClass
  metadata:
    name: batch-inference
  value: 100000
  preemptionPolicy: PreemptLowerPriority   # preempts training; realtime preempts it
  globalDefault: false
  description: "Batch inference (async generation). Same trust domain as realtime
    (no scrub); soft-SLA so Kueue-admitted. Preempts training, yields to realtime."
  ```

  ```yaml
  # clusterqueue-batch-inference-borrow.yaml — new, gpu-lending cohort:
  apiVersion: kueue.x-k8s.io/v1beta1
  kind: ClusterQueue
  metadata:
    name: batch-inference-borrow
  spec:
    cohort: gpu-lending          # borrows the same lendable pool training does
    namespaceSelector: {}
    preemption:
      reclaimWithinCohort: Any   # cohort may reclaim borrowed capacity
      withinClusterQueue: LowerPriority
    resourceGroups:
      - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
        flavors:
          - name: gpu-lendable        # borrow lendable, above training in the cohort
            resources:
              - { name: cpu,            nominalQuota: "512" }
              - { name: memory,         nominalQuota: 2Ti }
              - { name: nvidia.com/gpu, nominalQuota: 0, borrowingLimit: 64 }
          - name: gpu-warm-floor       # NEW capability: soak floor troughs, same domain
            resources:
              - { name: cpu,            nominalQuota: "512" }
              - { name: memory,         nominalQuota: 2Ti }
              - { name: nvidia.com/gpu, nominalQuota: 0, borrowingLimit: 64 }
  ```

  Preemption ordering (node-level, kube-scheduler): `inference-critical` 1000000 >
  `batch-inference` 100000 > `training-preemptible` 1000. Quota (Kueue, cohort
  `gpu-lending`): `platform-lendable` owns the pool; `batch-inference-borrow` and
  `training-borrow` both borrow, batch admitted first by workload priority.

- **Consequences:**
  - The value-case §4 priority stack (realtime → batch inference → R&D training)
    becomes expressible; without this tier the batch-inference recovery is a claim
    the platform cannot honor.
  - **Warm-floor trough backfill is now safe and is a new source of recovery** —
    but only for batch inference, and only because it yields with no scrub. The
    same move for training remains forbidden (R12, and the audit's warm-floor P0).
    The ResourceFlavor split (training → `gpu-lendable` only; batch → both) is the
    enforcement point and must be policy-guarded so a values file cannot grant
    training a warm-floor flavor.
  - **KTD6 is refined, not broken:** realtime serving still never queues; batch
    inference queues by design. Document the distinction so the "serving never
    enters Kueue" invariant is not read as "no inference ever enters Kueue."
  - The lending controller is unchanged for batch inference (no scrub, no drain
    wave); its scrub path stays training-only. Confirm the reclaim curve logic
    treats batch borrow and training borrow independently so shrinking one does not
    mis-drive the other.
  - **Open questions for implementation:**
    - Warm-floor batch via Kueue borrow (as speced) versus pure kube-scheduler
      backfill (no Kueue) — the latter is simpler for opportunistic trough soaking
      but loses cohort accounting. Decide before wiring.
    - Per-tenant quota for batch inference (the infra audit flags training-borrow
      has none; batch inference inherits the same gap if multiple B2B tenants
      submit batch work).
    - How `batch-inference-borrow`'s borrowingLimit curve interacts with training's
      during the morning reclaim: batch inference should reclaim *after* training
      (it is higher value and cheaper to reclaim), so the curves are not identical.
  - **Implementation gate:** this touches tenancy flavors and preemption, so it
    takes an independent review before merge and must not reopen the warm-floor
    deletion path (infra audit P0). Rides after the audit's P0 fixes, not before.
