---
hide:
  - toc
---

# Why the platform lends GPUs { .tufte }

This is a discussion of the problem the platform exists to solve and the idea at
its heart. It explains; it does not instruct. To run anything, see the
[tutorials](../tutorials/first-validation.md) or the [runbooks](../../runbooks/service-migration.md);
to look a name up, see [conventions](../conventions.md).

## Paying twice for the same silicon

GPU capacity is scarce and rented, and once released it may not come back. So
the inference fleet is held — never scaled down — to guarantee it is there when
customers need it. That guarantee has a cost that only shows up at night: when
customer traffic falls, the held fleet sits nearly idle, yet it is still paid
for. Meanwhile R&D needs to train, and because the inference fleet is not
safely shareable, R&D buys its *own* capacity at full price.

The result is paying twice for the same kind of hardware — an availability
premium on a fleet that is idle half the day, plus full price for training that
could have run on that idle fleet. The platform exists to end that double-pay:
lend the idle held GPUs to training at night, and take them back before the
morning customer ramp.

<div class="md-has-sidebar" markdown>
<main markdown>

The obstacle was never the economics; it was safety. On the old platform there
was no way to put training on an inference node and reliably evict it in time.
Lending was unsafe, so it never happened. Making it safe is what the rest of
the design is about.

</main>
<aside markdown>

The old platform: static ECS auto-scaling groups, no scheduler-level
preemption.

</aside>
</div>

## The node that must be two things at once

Lending forces a single GPU node to hold two pairs of opposite properties.

It must be **busy** — running training, so no paid capacity is wasted — and at
the same time **instantly free**, able to serve customer inference within a hard
latency floor the moment demand returns. And it must be **trusted** — customer
inference runs on it, under enterprise isolation obligations — yet also
**untrusted**, because arbitrary R&D training code ran on it minutes earlier.

Stated plainly, one node has to be busy and free, trusted and untrusted, at
once. That is a contradiction, and a design that tries to average it — a little
bit shared, a little bit isolated — gets the worst of both: neither the
utilization nor the safety. The way out is not to compromise on the axis but to
*separate* the opposing demands so each holds in its own place, time, or state.

## Separating the contradiction

Three separations carry the design, and each maps to a concrete mechanism.

![A 24-hour timeline of one node: a lendable node serves prod by day, goes idle in the evening, is lent to training overnight, drains through staged reclaim waves before the morning ramp, scrubs, and returns to prod; below it, the warm floor serves prod all day and never lends](../assets/diagrams/why-lending-day.svg){ .diagram }

<div class="md-has-sidebar" markdown>
<main markdown>

**In time.** A node is not busy and free simultaneously; it is busy during a
lending window at night and free during the day. The window opens off-peak and
closes with staged reclaim waves that start *ahead* of the morning ramp, so
capacity is already back before customers need it.

</main>
<aside markdown>

Capacity intent lives in git — the schedule is a file, not a pager.

</aside>
</div>

**In space.** Not every node lends. A never-lent *warm floor* is held aside
permanently to carry the latency guarantee no matter what the lending pool is
doing, while a separate *lendable* pool is the only capacity that ever spills to
training. The two are distinct node pools with distinct taints; a workload's
place in this split is enforced by policy, not convention. This is why a
customer-data pod that tries to tolerate the lendable pool is rejected — the
separation only holds if nothing can quietly cross it.

**In state (discard and recover).** Trust is not negotiated between tenants; it
is reset between them. When a lent node is reclaimed, it is not wiped in place —
the instance is terminated and a fresh one boots, so no GPU memory or on-disk
state can survive from the training tenant into the customer tenant. The trust
boundary is a clean-slate boundary.

Node-level lending like this comes first, before any finer-grained GPU sharing,
for two reasons that both favour safety over cleverness: the failure domain
stays whole (a wedged training job takes down only its lent node, never a shared
one), and the compliance story is simple enough to audit (a node served one
trust domain at a time). Finer sharing might reclaim more idle time, but its
economics are unproven and its isolation is harder to certify — so it waits for
evidence.

## Latency and utilization are opposite goals, deliberately

One more idea underpins the split, and it is worth stating because it looks like
inconsistency until you see it. The render path — customer inference — is
optimized for latency: it keeps headroom, a warm floor, capacity that is
sometimes idle *on purpose*. The training path is optimized for utilization:
idle capacity there is pure waste to be soaked up. The same slack that is a
feature on one path is a defect on the other. The platform does not pick one
global answer; it runs the two paths under opposite objectives and lets the
lending window move capacity between them.

## What this buys, and what it costs

Done right, the held fleet's night-time idle approaches zero, R&D training runs
on reclaimed hours instead of separately-bought capacity, and the double-pay
shrinks — while customer latency never regresses, because the warm floor and the
ahead-of-ramp reclaim protect it by construction.

The costs are real and named. The morning reclaim must never turn into a
latency breach, so it is rehearsed as a game-day before real traffic depends on
it. The clean-slate trust reset must satisfy an auditor, which is a decision
outside engineering's hands. And the whole win depends on there being enough
training work to soak the reclaimed hours — if there is not, the honest response
is to shrink the held fleet, not to force more lending. These are the platform's
open questions, held as assumptions with explicit triggers to revisit, not
buried.

## Related

- The reclaim mechanism — why serving is never scheduled through the quota
  layer — has its own discussion in the reclaim model *(planned:
  `reclaim-model.md`)*.
- The names, pools, taints, and priority classes referenced above are pinned in
  [conventions](../conventions.md).
- The operations that carry out reclaim, scrub, and capture are the
  [runbooks](../../runbooks/service-migration.md).
