# ADR 0002 — Training arbitrage via MultiKueue dispatch; inference stays put

- **Status:** accepted (grilling session, 2026-07-18)
- **Context:** ADR 0001 establishes multi-region as the product mechanism —
  the platform leverages GPU availability differences between regions.
  That needs an actor and a verb: what observes availability, and what moves.
  Karpenter is region-local and cannot see across regions. The repo's Kueue
  version already ships the MultiKueue CRDs (`MultiKueueCluster`,
  `MultiKueueConfig`), and each region's checkpoint bucket is region-local.
- **Decision:**
  - **What moves: training jobs, at placement time.** Submission targets a
    hub-level Kueue; MultiKueue dispatches each job to the spoke whose
    lendable pool can admit it. Jobs restart in-region against their
    region-local checkpoint bucket — arbitrage happens at placement, never
    as mid-run cross-region migration.
  - **What observes (phase 1): MultiKueue admission feedback itself.** A
    spoke that cannot admit does not get the job. No bespoke availability
    oracle is built for phase 1.
  - **What observes (phase 2): acquisition arbitrage.** ODCR/spot capacity
    is bought where availability trends favorable, using per-region
    provisioning-failure and price signals. Capacity follows demand;
    workloads follow capacity.
  - **What never moves: customer inference.** Data gravity and EU residency
    anchor each region's warm floor to its own customers. The system is
    precisely a training-arbitrage platform: training is the fungible
    workload, inference the anchored one.
- **Consequences:**
  - Next real increment after the single-region e2e proves the cell:
    **second spoke + MultiKueue config** (hub Kueue, per-spoke
    MultiKueueCluster, dispatch policy).
  - ADR 0001's open single-region failure story resolves: degrade to the
    warm floor (inference protected), shed training — to other regions once
    they exist; until then, shed means queue.
  - The lending controller stays region-local (per ADR 0001); MultiKueue
    sits above it and never touches Node objects.
  - The per-region terraform module and the spoke-label ArgoCD registration
    are the multiplication mechanism; adding a region must stay "instantiate
    module + register secret + add MultiKueueCluster".
