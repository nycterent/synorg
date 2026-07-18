# ADR 0005 — ODCR is capacity insurance; lending offsets the premium, and we measure it

- **Status:** accepted (grilling session, 2026-07-18)
- **Context:** The held book (infra/terraform/regions/pilot/odcr/) — 4×
  p5.48xlarge, 8× g6e.12xlarge, 3× g7e.2xlarge, eu-west-1a, unlimited
  duration — bills at full on-demand rate whether used or not: order of
  $350k/month of standing burn at eu-west-1 prices. Capacity reservations
  guarantee capacity but discount nothing. Nothing in the platform
  currently measures whether the lending machine justifies the hold.
- **Decision:**
  - **Position:** the warm floor's hold is SLO insurance sized by
    inference peak (p5-class capacity cannot be provisioned on demand);
    the lendable pool's hold is surge insurance whose premium is offset by
    training borrow. The platform's economic claim is explicit:
    `training GPU-hours captured + surge readiness ≥ held cost − commitment discounts`.
  - **Metrics (evidence plane, first-class):**
    - `utilization-of-held` = GPU-hours allocated ÷ GPU-hours held, per
      pool, alongside the existing GPU-hour attribution.
    - `idle-burn` = $/day of held-but-unallocated capacity, priced at
      on-demand rates.
  - **Floor target:** held fleet ≥ 70% allocated (rolling month). Breach
    feeds the quarterly ledger review (capacity-transition ledger), whose
    standing options are: shrink the reservation, widen the lending
    window, or re-justify the insurance sizing in writing.
  - **Commitment stacking (finance action):** Savings Plans / RIs stack on
    top of capacity reservations; holding without a commitment discount
    pays for insurance twice. Policy: the held book is covered by
    commitment discounts; the ledger review verifies coverage.
  - **Rejected:** hold-only-warm-floor with training on pure spot — it
    guts the surge readiness the lending design exists to provide.
- **Consequences:**
  - The evidence plane grows two metrics and the quarterly ledger review
    gains a standing economics agenda item.
  - Pilot/e2e sizing (cheap mode, ODCR g4dn×1) is exempt from the floor
    target — the target governs the production book.
  - The 70% floor and quarterly cadence are tunable; changing them means
    amending this ADR, not silently drifting.
