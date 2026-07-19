# ADR 0001 — Multi-region exists to arbitrage GPU availability, not for DR

- **Status:** accepted (grilling session, 2026-07-18)
- **Context:** The platform currently runs a single pilot spoke (eu-west-1).
  The plans defer "multi-region" as a later increment, which reads as if
  additional regions were a resilience feature to bolt on.
- **Decision:** Multi-region is a core capability driver, not disaster
  recovery. The system is *supposed to exploit differences in GPU
  availability between regions* — capacity, instance-family presence, and
  spot/reservation dynamics differ per region, and the platform's value
  includes placing GPU work where availability is. A single-region deployment
  is therefore an acknowledged pilot limitation, not a design position.
- **Consequences:**
  - Region-local control loops (the lending controller is region-local by
    construction) remain correct: regions are peers, each with its own
    warm floor and lending loop; arbitrage happens ABOVE the region.
  - The hub/spoke ArgoCD topology already anticipates this (spokes join via
    a cluster-secret label); adding a region must not require redesign.
  - Open (ADR pending): the arbitrage mechanism itself — what observes
    cross-region availability, what it moves (training jobs? borrow
    headroom?), and on what signal.
  - Open (ADR pending): the single-region failure story for the pilot
    period (degrade-to-warm-floor vs outage).
