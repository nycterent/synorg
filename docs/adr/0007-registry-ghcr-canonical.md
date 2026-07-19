# ADR 0007 — ghcr.io is the canonical registry; registry.synorg.io retires

- **Status:** accepted (grilling session, 2026-07-19)
- **Context:** Manifests pin images to `registry.synorg.io/platform/*`, a
  registry that has never existed (`synorg.io` is not even registered). Real
  images live in a private ECR (`platform/lending-controller:0.1.3`,
  `platform/inference-stub:0.1.0`), reachable only from the run account; the
  e2e path overrides image references to reach them. Fictional pins survive
  only because nothing resolves them at review time — a reader following a
  manifest hits a dead hostname.
- **Decision:** **`ghcr.io/nycterent/*` becomes the canonical registry.**
  - Manifests pin `ghcr.io/nycterent/<image>:<tag>`; the vanity-registry
    indirection dies rather than gaining a domain purchase and a fronting
    service.
  - Images are public alongside the public repo — anyone reading a manifest
    can `docker pull` what it names. EKS nodes pull public ghcr without
    auth machinery.
  - ECR is retired (repos deleted) only after the ghcr path passes a full
    clean-cycle e2e run. One registry; no mirror to drift.
- **Consequences:**
  - Build/push flow moves to ghcr (buildx contexts on the build machine
    already exist; auth via a classic PAT with `write:packages`).
  - In-region pull-speed loss versus ECR is negligible at these image sizes.
  - Until migration executes, `registry.synorg.io` remains in manifests as a
    known fiction — this ADR is the record that it is decided-dead, kept
    momentarily so the archived 6/6 run's commit remains bit-identical to
    what ran.
