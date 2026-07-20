# PRD/ADR — Multi-Region GPU Compute Platform on EKS (agent-first)

**Status:** draft v1 · 2026-07-17 · owner: Martynas · iterate freely

## Problem
Scarce GPU capacity is rented and deliberately never descaled (released capacity may not return). Result: prod inference fleet ~90% idle at night while R&D trains at 100% on separately-bought capacity — **paying twice**: an availability premium on the held fleet plus full price for training. The platform boundary (ECS static ASGs, no scheduler-level preemption) makes lending unsafe today. Two orchestration platforms; deploys pass through a bespoke compose-like env-spec translated by humans.

## Objective (one sentence)
End the double-pay: serve synchronous customer inference at guaranteed render-start latency while lending idle held GPUs to preemptible R&D training — on one Kubernetes substrate spanning multiple AWS regions, behind the industry-standard interface, consumable by engineers **and their agents**.

## Users
1. Product/service teams (deploy ~100 services) · 2. R&D (training jobs) · 3. Platform team (fleet, policy) · 4. **LLM agents acting for all of the above** — first-class consumer: full loop (propose→validate→observe→correct) without a human translator.

## Functional requirements
- **FR1 — GPU lending:** shared GPU node pools; prod inference preempts training via PriorityClass/quota; training checkpoint-tolerant; reclaim honors an eviction SLA.
- **FR2 — Latency floor:** render-start p95 ≤ target per region *including during morning reclaim*; never-lent warm floor per region.
- **FR3 — One substrate:** all workloads on EKS; ECS retired; GPU pools migrate first, web fleet second.
- **FR4 — Contract plane:** git = only write API (base + per-region overlays); one golden Helm chart, values(+schema) = the interface; env-spec lives only as migration bridge with dated retirement.
- **FR5 — Actuation plane:** reconcilers only (ArgoCD apps, Karpenter capacity); no imperative prod access; per-identity attribution (humans and agents as distinct principals).
- **FR6 — Evidence plane:** telemetry as read-API (PromQL/logs/events); machine-readable SLOs; lending state + preemption events + per-team GPU-hour attribution queryable.
- **FR7 — Policy-as-code:** Kyverno/OPA verdicts replace human approval queues; capability tiers by blast radius — autonomous (ns-scoped, policy-passing, non-prod) / human-by-exception (prod topology, quotas, node pools) / never (cross-tenant, secret material).
- **FR8 — Multi-region:** cluster-per-region; region set = GPU availability ∧ training-data gravity ∧ customer data residency (EU); scarcity surfaced as structured evidence ("asked 8×G7e, got 3") feeding a fleet-shaping loop.

## Non-functional requirements
- **NFR1 — Isolation:** node-level lending, scrub/reimage-on-return baseline; customer-data workloads never share a node with R&D concurrently (MIG/time-slicing only with evidence). Enterprise-trust (SOC2/ISO) auditable.
- **NFR2 — Loop speed:** validate (helm template + dry-run + policy) identical locally and in CI, seconds not minutes; rendered diff in every PR; deterministic, actionable admission errors.
- **NFR3 — No new formats:** zero bespoke DSLs in end state; schemas ARE the docs; runbooks are executable playbooks in-repo.
- **NFR4 — Failure containment:** preemption storm at morning ramp must not breach FR2; training failure modes (driver wedge, memory fragmentation) contained to lent nodes.
- **NFR5 — Secrets/approvals:** centralized secret management preserved; approvals become policy verdicts, humans review exceptions.

## Success metrics
1. Render-start p95 per region, incl. reclaim window (FR2) — no regression vs ECS baseline.
2. Allocation-idle on held GPUs off-peak → near zero; kernel utilization reported separately per workload class.
3. % of R&D training backlog served from reclaimed hours; double-pay reduction in $/GPU-hour.
4. Held-capacity size justified by measured morning-peak demand + scarcity data; quarterly premium review.
5. Deploy path: zero human-translation steps; time-from-PR-to-converged; % changes auto-approved by policy.
6. Attribution: 100% of GPU-hours attributed to a team/workload from day one.

## Explicit non-goals
SQS/queue replacement (stated low value) · active-active multi-region for scarcity alone (readiness only) · abstracting Kubernetes away from consumers · self-hosted data stores (Atlas/RDS stay).

## Open questions (carry into design)
1. Where does R&D train today — same regions as idle inference capacity, or region/data-gravity gap?
2. "90% idle" = allocation-idle or kernel-idle? (Different fixes.)
3. Is training backlog deep enough to soak nights in every region (whose night — global customers rotate the window)?
4. Preview/rehearsal stage: rendered-diff sufficient, or synthetic-load rehearsal region for scheduling changes (can't dry-run a preemption storm)?
5. Eviction SLA number: what checkpoint cadence can training tolerate vs what reclaim latency does FR2 need?
6. Compliance verdict on node reuse between customer-data and R&D workloads (scrub sufficient per auditor?).

## Key decisions (ADR-style, one line each)
- **D1:** Git as sole write API; reconcilers as sole actuators. *Rationale: audit + rollback + agent safety cage in one mechanism.*
- **D2:** Golden chart values(+schema) as the permanent interface; env-spec = bridge with retirement date. *Rationale: two layers were doing one layer's job; agents/hires have priors on standard surface only.*
- **D3:** Node-level lending with scrub-on-return before any finer GPU sharing. *Rationale: failure-domain + compliance safety first; economics of finer sharing unproven.*
- **D4:** Optimize the render path for latency, training path for utilization. *Rationale: inverted objectives — headroom is a feature on one path, waste on the other.*
- **D5:** Capacity intent lives in git; scarcity is evidence, not an error. *Rationale: fleet-shaping must run as a data loop, not firefighting.*
