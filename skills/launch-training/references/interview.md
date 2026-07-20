# Step 1 — Interview and scaffold

Drive this step from `charts/training-job/values.schema.json` — read it at run
time so the field list can never drift from the chart. Prompt only for what the
schema marks required plus the high-value optionals; take the schema's defaults
for everything else.

## Ask for these

**Required** (schema `required`: `team`, `queue`, `gpu`, `image`):

- **`team`** — the owning team's short name. Becomes the `team.synorg.io/name`
  label; a GPU pod without it is denied at admission (`require-team-label`).
- **`queue`** — the Kueue LocalQueue. **Default it to `team-<team>`** (the
  `conventions.md` naming rule) and only ask if the engineer needs an override.
- **`gpu`** — GPUs per worker pod (integer ≥ 1).
- **`image.repository`** and **`image.tag`** — the trainer image. Convention is
  `ghcr.io/nycterent/synorg/<team-domain>/...`. No default; must be a real,
  pullable image.

**High-value optionals** (ask, but offer the default):

- **`workers`** — worker pods = torchrun-elastic nodes (integer ≥ 1, default 1).
- **`checkpoint.dir`** — where checkpoints land (backed by the shared store).
- **`checkpoint.intervalSeconds`** — **schema caps at 300** (the KTD12 ≤5-min
  lost-work budget). If the engineer asks for more, explain the cap and hold at
  300 rather than emitting an invalid file.

Leave `command`, `resources`, and `backoffLimit` at their scaffold defaults
unless the engineer volunteers a change — the chart's defaults are the safe
preemption-aware baseline.

## The checkpoint contract (surface it, don't skip it)

Before scaffolding, make sure the engineer understands: **the image must resume
from the latest checkpoint under `CHECKPOINT_DIR`.** Preemption deletes a worker
pod; the platform re-admits it, and the run only makes progress if the image
checkpoints often and resumes. A run whose image can't resume will restart from
zero on every preemption. This is the engineer's responsibility, not the
platform's — the pre-flight step re-confirms the acknowledgement.

## Emit the values file

Produce a values file shaped exactly like `charts/training-job/ci/basic-training.yaml`
(the canonical minimal run). Keep it minimal — only the keys the engineer set
plus the required ones. Hand it to Step 2 (pre-flight) and Step 3 (validate); do
not proceed to a PR until both pass.
