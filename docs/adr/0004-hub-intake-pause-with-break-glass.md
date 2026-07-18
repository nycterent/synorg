# ADR 0004 — Hub outage pauses training intake; spoke-direct is break-glass

- **Status:** accepted (grilling session, 2026-07-18)
- **Context:** ADR 0002 makes the mgmt cluster's hub Kueue the single front
  door for training submission. A hub outage therefore stops NEW training
  placements. The blast radius is narrower than it sounds: running jobs are
  owned by each spoke's own Kueue and keep running; inference never crosses
  the hub (KTD6); ArgoCD sync pauses but spokes keep their last-synced
  state; and the hub's substrate (EKS control plane) is AWS-managed
  multi-AZ, so the realistic outage is a regional/mgmt-cluster event.
- **Decision:** **(a) accept the pause, with (b) documented break-glass.**
  - Posture: hub down means no new training placements for the duration.
    Training is the deferrable tier by design — a platform that preempts
    training for inference daily can pause training intake during a rare
    hub outage.
  - Break-glass: direct submission to a spoke's LocalQueue. This is
    quota-safe by construction — borrowingLimit is enforced by the spoke's
    own Kueue regardless of submission path — but bypasses arbitrage and
    is NOT a supported everyday path. Trigger: hub down for more than
    4 hours AND a training job is genuinely urgent. Documented in
    `runbooks/training-intake-break-glass.md`.
  - Hub HA (standby manager cluster) is rejected until multi-region
    operation demonstrates a need.
- **Consequences:**
  - Until the hub exists (pilot phase), spoke-direct submission is simply
    the normal path; this ADR's posture activates when MultiKueue lands
    (ADR 0002's second-spoke increment).
  - The break-glass runbook must stay working forever once the hub is the
    front door — it is exercised (smoke-level) whenever intake paths change.
  - Monitoring consequence: hub Kueue availability is a platform SLI, but
    pages nobody at night — the pause posture makes it a business-hours
    concern.
