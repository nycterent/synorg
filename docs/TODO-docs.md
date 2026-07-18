# Documentation TODO — organise by Diátaxis

Framework: <https://diataxis.fr/>. Four modes on two axes (action↔cognition,
acquisition↔application). Every doc serves exactly one; the top defect is a page
serving two at once. Work in small closed increments — pick one page, move it to
its mode, commit. Don't gate value on a full reorg.

## Where each mode lives (target)

| Mode | Serves | Home | Status |
|---|---|---|---|
| **Tutorial** — learning, guided lesson | a newcomer acquiring the craft | `docs/tutorials/` | **missing — highest-value gap** |
| **How-to** — a goal, competent worker | an operator with a task | `runbooks/` | strong, already how-to shaped |
| **Reference** — information | someone looking a fact up | `docs/reference/` + chart/schema files | strong but scattered |
| **Explanation** — understanding, why | someone building a mental model | `docs/explanation/` | **missing — trapped in the plan** |

## Current inventory → mode audit

**Already correct (leave, or just relocate):**
- `runbooks/{capacity-carve,node-scrub,gpu-node-quarantine,training-onboarding,game-day,service-migration}.md` — how-to. Keep. (One flagged thin on executable commands: `service-migration.md` steps 5-7 — see residual findings.)
- `docs/conventions.md`, `charts/*/README.md`, `charts/*/values.schema.json`, `docs/slo-catalog.md`, `docs/agent-interface.md`, `docs/env-spec-retirement.md`, `docs/ecs-retirement.md` — reference. Keep; consider gathering the loose `docs/*.md` reference files under `docs/reference/`.
- `docs/plans/*`, `docs/residual-review-findings/*` — neither user-docs nor Diátaxis modes; they are decision/record artifacts. Leave out of the docs tree.

**Mis-moded — split or move:**
- `docs/capability-tiers.md` — fuses reference (the tier→mechanism table) with explanation (why blast-radius drives the split). Split: table stays reference; the "why tiers" prose moves to `docs/explanation/capability-model.md`.
- `docs/region-set.md` — fuses reference (the region-set predicate) with explanation (why data-gravity ∧ residency ∧ availability). Split likewise.

## Actions (each a standalone increment)

- [x] **T1 — Tutorial: "Validate the platform on your laptop."** `docs/tutorials/first-validation.md` — DONE (2026-07-17). Guided lesson spined on `make demo` + `make validate`; no choices/digressions; links out to E1 and add-a-service for the next steps.
- [ ] **T2 — Tutorial: "Add your first service."** `docs/tutorials/add-a-service.md`. Copy `example-inference.yaml`, edit values, `make validate`, watch it fail on a bad key, fix it. Teaches the values-are-the-interface idea by doing.
- [x] **E1 — Explanation: the double-pay problem and the lending model.** `docs/explanation/why-lending.md` — DONE (2026-07-17). Discussion of the double-pay, the busy∧free/trusted∧untrusted contradiction, and the time/space/discard-recover separation; no steps; links to runbooks + conventions.
- [ ] **E2 — Explanation: why serving is never Kueue-admitted.** `docs/explanation/reclaim-model.md`. From KTD6 + the ARIZ layered-reclaim resolution: borrowingLimit curve (planned) vs PriorityClass preemption (emergency). This is the most-misunderstood design point — worth a standalone why.
- [ ] **E3 — Explanation: the capability-tier model.** `docs/explanation/capability-model.md`. The "why blast radius decides autonomy" half of capability-tiers.md.
- [ ] **R1 — Reference tidy.** Gather loose `docs/*.md` reference under `docs/reference/`; leave a landing page (below) pointing at them. Mechanical move, no rewrite.
- [x] **L1 — Docs landing page.** `docs/index.md` — DONE (2026-07-17). Diátaxis card grid routing readers by need (learning/task/fact/why). (Named `index.md` not `README.md` — MkDocs home convention.)
- [x] **L2 — HTML docs site.** `mkdocs.yml` + Material for MkDocs — DONE (2026-07-17). Nav = the 4 quadrants; `runbooks/` pulled in via the `docs/runbooks` symlink; `make docs-serve` / `make docs-build` (pinned venv from `docs/requirements.txt`); `.github/workflows/docs.yaml` builds `--strict` and deploys to GitHub Pages on push to main. Builds clean strict (18 pages).
- [x] **E4 — Explanation: the test ladder.** `docs/explanation/testing.md` — DONE (2026-07-17, plan 002 U8). Why validate → integration → smoke → e2e is shaped this way; per-tier proves/cannot-see table; the kind/Karpenter (kwok) boundary; two-cluster isolation (post-live-run correction); no-vacuous-pass; why e2e is manual + cheap mode.
- [ ] **X1 — Cross-link.** From each explanation, link to the runbook that applies it and the reference that pins its names; from tutorials, link onward to the how-to for real work. Modes stay separate but connected.

## Infrastructure-engineer docs (added 2026-07-17)

Gap found: the runbooks were all per-operation; nothing covered deploying,
maintaining, or understanding the system whole. Filled:

- [x] **A1 — Explanation: Architecture.** `docs/explanation/architecture.md` — the four planes, component map, control + data flow, load-bearing decisions, single points. The onboarding read for a new infra engineer.
- [x] **A2 — How-to: Deploy the platform from zero.** `runbooks/deploy-platform.md` — ordered bootstrap (ODCR capture → hub → pilot → register spoke → policy → scheduling → evidence → game-day gate), verify-before-terminate throughout.
- [x] **A3 — How-to: Operate & maintain.** `runbooks/operations.md` — routine (warm-floor resize, quarterly held-fleet review, cred rotation, upgrades) + on-call (preemption storm, wedged node, hub outage, stop-lending) + scarcity response.

Still thin: an **operations reference** (exact commands/thresholds per task) could
be split out of A3 if A3 grows; hold until it earns it.

## Guardrails

- Author for the human, not the grid — if a split would hurt the reader, look again (usually two fused things), but don't mutilate a good page to satisfy the scheme.
- Tutorial must not explain, offer choices, or chase completeness. How-to must not teach. Reference must not instruct or opine. Explanation must not give steps.
- Prefer moving content to rewriting — mis-moded content is usually the right content in the wrong place.
