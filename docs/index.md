# synorg platform docs

Multi-region GPU compute platform on EKS. These docs are organised by
[Diátaxis](https://diataxis.fr/) — pick the section that matches what you need
right now, not the topic.

<div class="grid cards" markdown>

- **[Tutorials](tutorials/first-validation.md)** — *Learning.* Guided lessons
  that start from zero. Begin with [Validate on your
  laptop](tutorials/first-validation.md).

- **[How-to (runbooks)](../runbooks/deploy-platform.md)** — *A task.* Executable
  playbooks for operators: [deploy the platform](../runbooks/deploy-platform.md),
  [operate & maintain it](../runbooks/operations.md), migrate a service, scrub a
  node, run a game-day.

- **[Reference](conventions.md)** — *A fact.* The pinned names, schemas, tiers,
  and SLOs. Start with [conventions](conventions.md).

- **[Explanation](explanation/architecture.md)** — *Why.* The ideas behind the
  design: the [architecture](explanation/architecture.md) map, and [why the
  platform lends GPUs](explanation/why-lending.md).

</div>

## What this platform does

It ends GPU double-pay: customer inference holds a latency floor while idle held
GPUs are lent to preemptible R&D training, on one Kubernetes substrate per
region, behind git-as-the-only-write-API. The [why-lending
explanation](explanation/why-lending.md) is the place to start if that sentence
raises questions.

## Building these docs

```bash
make docs-serve    # live preview at http://127.0.0.1:8000
make docs-build    # static HTML into site/
```
