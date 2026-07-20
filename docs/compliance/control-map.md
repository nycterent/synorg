# Compliance control map — readiness, not certification

**Status: designed-toward, NOT audited or certified.** This document maps the
major control domains of SOC 2 (Trust Services Criteria), ISO/IEC 27001:2022,
ISO/IEC 27701:2019, and ISO/IEC 42001:2023 to synorg's *technical design
evidence*, and marks the gaps honestly. It is a readiness aid for a future audit.
It is **not** an audit, confers **no** certification, and must not be presented as
either. synorg is a single-region proof-of-concept; it holds none of these
certifications.

## What a codebase can and cannot satisfy

These frameworks are roughly two halves:

- **Technical controls** — access control, encryption, change management, logging,
  isolation, secure development. A well-designed system produces genuine evidence
  here, and that is what this map covers.
- **Organizational / process controls** — security policies, personnel screening
  and training, risk assessment and management review, incident-response *process*
  (with people on call), vendor management, business continuity, and — for **SOC 2
  Type II specifically — controls demonstrably operating over a 6–12 month
  period**. No amount of code satisfies these. They require a legal entity, staff,
  running processes, and time.

So the honest bottom line up front: **synorg's architecture can be designed to
pass the technical control set; it cannot, as a solo POC, pass a full SOC 2 Type
II or ISO certification today** — the organizational layer and operating history
do not exist. This map shows how close the *technical* half is and what remains.

Status legend: **Addressed** (design provides real evidence) · **Partial**
(evidence exists but has a known gap — see the infra audit) · **Gap** (not yet
built) · **Org-layer** (cannot be satisfied by code; needs an organization).

---

## Cross-cutting strengths (evidence reused across every framework)

These design choices are the load-bearing technical evidence and recur below:

- **Git is the only write API** — every change is a reviewed pull request;
  ArgoCD reconciles. This is an immutable, attributable **change-management and
  audit trail** by construction (`docs/capability-tiers.md`,
  `docs/agent-interface.md`, ADR 0006).
- **Least privilege / no standing credentials** — humans and agents open PRs and
  read the SLO API but never hold cluster credentials; the lending controller's
  RBAC is proven a *subset* of what it uses by an offline test
  (`controllers/lending/test.sh` RBAC-subset check); ArgoCD uses a read-only
  deploy key; hub admin is bootstrap-then-break-glass.
- **Tenancy isolation enforced at admission** — `policies/kyverno/tenancy-guard.yaml`
  (Enforce) and `policies/vap/deny-cross-namespace-refs.yaml` (ValidatingAdmission
  Policy, fail-closed) block cross-tenant placement at the API server.
- **Scrub + zero-net-release ledger** — a node handed across the inference↔R&D
  trust boundary is discarded to a fresh instance (GPU memory never crosses), and
  a per-cycle ledger proves it (`controllers/lending/`, `runbooks/node-scrub.md`,
  `runbooks/capacity-carve.md`). This is auditable data-isolation evidence.
- **Hardened control plane** — ArgoCD `exec.enabled:false`, `server.insecure:false`,
  Dex disabled, `Prune=false` (`clusters/mgmt/argocd/install.yaml`); private EKS
  API endpoints by default (`infra/terraform/.../main.tf`).
- **CI as a gate** — `make validate` (helm → kubeconform → kyverno → policy tests)
  on every PR; the e2e tier uses GitHub OIDC, no static cloud keys
  (`.github/workflows/`).

---

## SOC 2 — Trust Services Criteria

| TSC area | synorg technical evidence | Status |
| --- | --- | --- |
| **CC6 Logical access** | Least-privilege, no standing creds, RBAC-subset proof, break-glass audited path (ADR 0004), admission policies | **Partial** — strong design; but tenancy rules key on *self-asserted* pod labels (`tenancy-guard.yaml`) and there is no CODEOWNERS/branch-protection enforcing the capability tiers (infra audit P0-1) |
| **CC7 System operations / monitoring** | Prometheus evidence plane, recording rules, SLO definitions, game-day rehearsal | **Partial** — metrics exist; alerting/incident-detection maturity is thin, and stuck-drain/liveness alerts are unbuilt |
| **CC8 Change management** | Git-only writes, mandatory PR, CI `make validate`, ArgoCD reconcile, digest-pinnable images | **Addressed** (technically) — this is synorg's strongest area |
| **CC1–CC5 Control environment, risk assessment, monitoring of controls** | — | **Org-layer** — governance, risk process, management review: no organization exists |
| **A1 Availability** | Warm-floor insurance, staged reclaim, PDBs/HPA, multi-AZ, reclaim-before-ramp | **Partial** — designed; single-region, no per-tenant quota, teardown fragility (audit) |
| **C1 Confidentiality** | Checkpoint-store SSE + public-access-block + versioning, ESO-only secrets (`deny-inline-secrets.yaml`), scrub | **Partial** — encryption present; checkpoint store uses the AWS-managed KMS key with no bucket policy (audit P2) |
| **PI1 Processing integrity** | Zero-net-release ledger, scrub-proof (new instance-id), deterministic GitOps | **Addressed** (for the capacity domain) |
| **Type II operating effectiveness** | — | **Org-layer** — requires 6–12 months of evidence of controls operating; not possible for a new POC |

---

## ISO/IEC 27001:2022 (ISMS — Annex A, four themes)

| Theme | Representative controls | synorg evidence | Status |
| --- | --- | --- | --- |
| **A.8 Technological** | Access control, cryptography, secure development, logging, network security, data-leakage prevention, capacity management | RBAC least-priv, SSE encryption, CI/policy gates, network policies (`lendable-networkpolicy.yaml`), admission isolation, capacity governance (lending) | **Partial** — broad coverage; gaps: self-asserted labels, KMS scoping, logging→SIEM, secret rotation |
| **A.5 Organizational** | Policies, roles, threat intel, supplier security, incident management | Change-control via GitOps; incident *runbooks* exist (scrub, quarantine, break-glass) | **Partial/Org-layer** — runbooks yes; no security policy set, no defined incident-command roles (audit), no supplier program |
| **A.6 People** | Screening, awareness/training, disciplinary, NDA | — | **Org-layer** — needs staff |
| **A.7 Physical** | Facilities, equipment | AWS shared-responsibility (inherited from the CSP) | **Addressed via inheritance** — cite AWS's own attestations |
| **Clause 4–10 (the ISMS itself)** | Scope, risk assessment/treatment, objectives, internal audit, management review | — | **Org-layer** — the management system does not exist |

---

## ISO/IEC 27701:2019 (PIMS — privacy extension to 27001)

synorg is *infrastructure*: it runs the internal customer's inference/training,
which processes that customer's data. Most PIMS obligations land at the
application/organization layer, but the platform contributes isolation evidence.

| PIMS area | synorg evidence | Status |
| --- | --- | --- |
| **Privacy by design / data minimization at the platform** | Trust-domain isolation (R9), scrub-on-return (no customer-data residue reaches R&D), region-aware placement | **Partial** — strong isolation primitive; but the scrub/tenancy relies on labels + the bidirectional-scrub gap (ADR 0009) is unimplemented |
| **Records of processing, lawful basis, consent, data-subject rights (DSAR)** | — | **Org-layer / app-layer** — not an infrastructure concern; needs process |
| **PII controller/processor responsibilities, DPAs** | The scrub + zero-net-release ledger is *auditable evidence a processor can show* that training never accessed customer inference data | **Partial** — the evidence artifact is real and valuable; the surrounding DPA/process is org-layer |
| **Data retention / deletion** | Checkpoint-store lifecycle (noncurrent-version expiry); scrub discards instances | **Partial** — lifecycle exists; incomplete-multipart cleanup missing (audit); formal retention policy is org-layer |

---

## ISO/IEC 42001:2023 (AIMS — AI management system)

synorg is AI-serving infrastructure (a GPU platform for inference + training),
so 42001 is the most directly relevant of the four — but it too is largely a
*management system* standard.

| AIMS area | synorg evidence | Status |
| --- | --- | --- |
| **AI system lifecycle & change control** | GitOps-governed deploy of all AI-serving workloads; reviewed PRs; reproducible (digest-pinnable) images; staged validation ladder | **Addressed** (technically) — the lifecycle *mechanics* are strong |
| **Resource & capacity governance for AI** | The lending/reclaim controller, utilization-of-held + idle-burn metrics, warm-floor SLO insurance — turning held GPU capacity into a measured, governed decision | **Addressed** — this is arguably synorg's most 42001-aligned contribution |
| **Data governance for AI** | Tenancy isolation between inference and training data domains; scrub boundary | **Partial** — isolation primitive present; bidirectional scrub for customer-data batch on lendable is designed (ADR 0009), not built |
| **AI risk / impact assessment, transparency, human oversight** | Capability tiers gate what an agent may auto-merge vs. what needs a human (`docs/capability-tiers.md`, `docs/agent-interface.md`) | **Partial** — the human-in-the-loop *mechanism* exists; formal AI impact assessments and transparency records are org-layer |
| **AI management system (policy, objectives, review)** | — | **Org-layer** — does not exist |

---

## The gaps, collected

**Technical (closable in-repo — several are tracked in the infra audit):**
- Tenancy/secret policies trust self-asserted pod labels — defense-in-depth, not
  airtight (`docs/audits/2026-07-20-srs-lens-infra-audit.md`).
- No CODEOWNERS / branch protection enforcing the capability tiers (audit P0-1).
- Alerting/monitoring maturity: stuck-drain, liveness/tick-success, quota.
- Checkpoint store on AWS-managed KMS key, no bucket policy; multipart cleanup.
- Secret rotation; image provenance beyond digest-pinning (cosign/binary-auth).
- Centralized, tamper-evident audit logging → a retained log store / SIEM.

**Organizational (cannot be closed by code — needed to actually pass an audit):**
- An ISMS/PIMS/AIMS: scope, risk assessment + treatment, Statement of
  Applicability, objectives, internal audit, management review.
- Security policy set, personnel screening + security training, vendor management,
  a staffed incident-response and business-continuity process.
- For SOC 2 Type II: **6–12 months of the above operating, with evidence.**
- An engagement with an accredited certification body / SOC 2 auditor.

## Bottom line

synorg's design already produces strong, genuine evidence for the **technical**
control set — its change-management (git-only, reviewed, reconciled),
least-privilege, admission-enforced tenancy isolation, and the scrub + ledger as
auditable data-isolation proof are real audit assets, and the capacity-governance
story maps unusually well to ISO 42001. To *pass* any of these certifications, the
missing half is an **organization**: policies, people, running processes, and — for
SOC 2 Type II — operating history. This map is the honest starting point for that
work, not a claim that it is done.
