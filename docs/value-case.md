# Value case — why run the pilot

For the Head of Platform deciding whether synorg earns a real pilot. Its deeper
job is to arm the decision that comes after the pilot: the production
keep-or-shrink call on a large standing cost, which Finance owns. So the framing
here is deliberately finance-legible, even though the pilot itself is a
platform-team call.

The honest version up front: lending is not a payback machine, and pretending
otherwise fails the first finance review. The value is measured de-risking and
governance of a large standing cost you already pay, plus a provable
data-isolation control for a customer serving external businesses.

All dollar figures below are **illustrative**, computed from the pilot held book
in ADR 0005. Swap your own fleet, window, and prices; the arithmetic and its
levers are what matter, not these specific numbers.

## 1. The workload reality: three classes, not two

synorg serves an internal customer: a business unit running B2B services. That
customer puts three workload classes on the held fleet, and they differ on two
axes that do not move together, SLA hardness and trust domain:

| Workload | SLA | Trust domain |
| --- | --- | --- |
| **Realtime inference** (interactive B2B API) | hard (ms), spiky, diurnal | customer data |
| **Batch inference** (async generation, e.g. text-to-video) | soft (deadline, mins to hours), revenue | customer data (same as realtime) |
| **R&D training** (model development) | softest (best-effort, internal) | different (must be scrubbed) |

The split is the whole game. Batch inference is soft-SLA but shares realtime's
trust domain, so a node moving between them needs no scrub. R&D training is also
soft-SLA but crosses the trust boundary: it must never retain a byte of
customer-inference GPU memory, so a node handed from inference to training and
back has to be scrubbed. Everything below follows from those two facts.

## 2. The contradiction, and how synorg resolves it

The held fleet embodies a physical contradiction. The same scarce GPU capacity
must be **dedicated to inference**, to hold a latency SLA you cannot buy on
demand, and **used by other work**, or you pay to hold it idle. There are only a
handful of ways to resolve that:

- **Separate capacity (space).** Buy distinct fleets for each. This is the status
  quo, and the double-pay.
- **Time.** Same GPU, inference when it needs it, other work when it doesn't.
  synorg's core move.
- **Condition (priority).** One pool, inference preempts everything on demand.
  Plain Kueue or kube-scheduler priority.
- **Silicon (MIG).** Partition one GPU into hardware-isolated slices, run both at
  once.
- **Market.** Rent pooled capacity from a neocloud and let someone else hold the
  idle.

synorg uses time-separation for the cross-domain (R&D) work, plus a warm floor it
never lends for the unpredictable inference spikes. Why not the simpler
condition-preemption? Because eviction across the trust boundary is not instant.
R&D training must checkpoint, drain, and scrub the GPU before inference can safely
reuse it, none of which fits inside the milliseconds a latency SLA allows. So
synorg reclaims ahead of predicted demand (before the morning ramp) rather than
reacting to it, and the warm floor absorbs whatever the prediction misses.

That resolution only earns its complexity where three preconditions hold:

1. **GPU is scarce.** You cannot buy inference capacity on demand, so releasing
   the fleet is not reversible. In 2026 this is market reality: p5/H100 on-demand
   is effectively sold out, and capacity reservations bought in advance are the
   only guaranteed path.
2. **The trust boundary is real.** Naive pooling of R&D training with
   customer-data inference violates isolation the customer is contractually on the
   hook for.
3. **Scrub and checkpoint latency are nonzero.** You cannot preempt reactively
   fast enough to protect a hard SLA.

Remove any one and a simpler resolution wins: abundant capacity means buy per use,
a soft boundary means one Kueue pool, instant isolation means MIG in silicon.
Those three preconditions are the honest scope of when synorg is the right tool.

## 3. The cost being attacked

Scarce GPU is rented and deliberately never descaled, because released capacity
may not return. Two bills land every month, both inside one internal customer's
budget:

- **Held-fleet burn.** The reserved book bills at full on-demand whether used or
  not. The pilot book (4× p5.48xlarge, 8× g6e.12xlarge, 3× g7e.2xlarge) is on the
  order of **$350k/month** of standing burn (ADR 0005).
- **Separately-bought training.** R&D trains on its own GPUs while the inference
  fleet sits idle overnight. You pay the availability premium on the held fleet
  and full price for training capacity. That is the double-pay, and here it is
  entirely internal: one customer paying both bills.

## 4. What synorg recovers: the priority stack

At any moment the held fleet's capacity is one of three things:

1. **Serving inference.** During the day, most of it, since the fleet is sized for
   the daytime peak.
2. **Surge headroom held on purpose.** The warm floor, insurance against a spike
   you cannot buy your way out of. This idle is not recoverable; it is the product.
3. **Idle long enough to fill safely.** Capacity that will stay free long enough
   to reclaim ahead of demand.

Only bucket 3 is recoverable, and it fills as a **priority stack ordered by
value**:

- **Realtime inference** always wins.
- **Batch inference** fills next. Same trust domain as realtime, so handing a node
  back needs no scrub, just checkpoint and requeue. That makes it safe to soak
  daytime troughs, not only overnight, with plain priority scheduling and no
  lending machinery. Its value per GPU-hour is customer revenue (or avoided batch
  capacity), not a training substitute. If the customer runs a batch B2B product,
  this demand is endogenous and near-certain, not the speculative backlog the
  recovery math usually worries about.
- **R&D training** fills the residual overnight idle. This is the cross-domain
  slice that needs synorg's lending controller, scrub, and reclaim-before-ramp,
  priced at the training-substitute rate.

The illustrative table below is that **R&D-residual slice alone**, the smallest
and last filler on the stack, from ~35 lendable GPUs across an 8.5-hour window:

| Utilization of the lendable window | Training GPU-hours captured /mo | Value recovered /mo | Share of the $350k burn |
| --- | --- | --- | --- |
| 50% | ~4,500 | ~$7–11k | ~2–3% |
| 70% (the ADR 0005 floor) | ~6,250 | ~$9–16k | ~3–5% |
| 90% | ~8,000 | ~$12–20k | ~3–6% |

(Training price band $1.5–2.5/GPU-hr, L40S-class.) Read correctly, the
single-digit-% figure is the training residual, not the recovery. Priced across
the whole stack, with batch inference at revenue on top of R&D at substitution,
the recoverable value is materially larger and far more certain. **Lending does
not pay for the fleet.** The priority stack, led by the customer's own batch
inference, is where the real recovery is; R&D lending is the last slice, not the
headline.

## 5. What synorg does *not* do

The boundary matters as much as the claim:

- **Daytime simultaneous R&D demand is out of scope.** synorg time-shifts R&D
  training into inference's idle hours. It does not hand R&D guaranteed daytime
  capacity. A researcher who needs a GPU at 2 p.m. runs on R&D's own capacity or
  queues for the window.
- **Daytime idle is not a lending target.** When inference is off-peak mid-day,
  that spare capacity is either surge headroom you must keep or evidence the fleet
  is oversized. Neither is something to lend; the second is a signal to shrink.
- **Recoverable value equals the overlap** between inference's idle hours and
  time-flexible demand (batch inference plus R&D backlog). No overlap, no recovery.
  That overlap is a property of the customer's workload rhythm, which the pilot
  measures rather than assumes.

## 6. What actually justifies the held book

The fleet is affordable for reasons lending only supplements:

- **SLO insurance.** p5/H100-class capacity cannot be provisioned on demand, so
  the warm floor is bought to give customer inference guaranteed render-start
  latency. This is the primary justification, and it holds with or without lending.
- **Commitment discounts.** Savings Plans and RIs stack on top of capacity
  reservations (ADR 0005). This is where most of the affordability comes from; the
  ledger review verifies coverage.
- **Compliance isolation.** The scrub-on-return and the zero-net-release ledger
  are not only reliability mechanisms. For a customer serving external businesses
  under a data-protection contract, they are an auditable control: per-cycle
  evidence that training never retained a byte of customer-inference memory,
  something the customer can show its own auditors and clients.
- **Lending margin.** The residual recovery above, real and measured, and marginal
  against the burn.

## 7. The pilot's real value: de-risk and govern

Today the $350k/month is spent **blind**. Nothing measures whether it earns its
keep. synorg makes lending *safe* (the walking skeleton proved the full lend,
reclaim, scrub, and rejoin cycle with zero-net-release and inference latency held),
which turns a standing cost into a governed one via two numbers:

- **`utilization-of-held`**, GPU-hours allocated ÷ held, per pool. Below the 70%
  floor for a rolling month, the options are to shrink the reservation, widen the
  window, or re-justify the sizing in writing. One caveat: shrinking a held GPU
  book is a one-way door. In a shortage the released capacity may not return at any
  price, so a shrink is a deliberate bet the measurement must inform, not a reflex.
- **`idle-burn`**, $/day of held-but-unallocated capacity at on-demand rates. The
  premium the lending machine offsets, tracked instead of assumed.

Because the customer is internal, these two metrics are also a **chargeback
lever**. The platform can allocate the held cost to the BU by measured use and
hold it accountable for its own sizing. De-risking becomes FinOps governance.

The payoff is not the ~$12k/month of lending revenue. It is that **you stop paying
$350k/month on faith and start paying it on evidence**, with a safe lever (lending)
and, for a B2B customer, a compliance proof (the ledger) on top.

Gate the whole case on one premise: **you cannot shrink the insurance.** If you
could, you would measure and shrink and skip the platform, since a FinOps
dashboard measures `utilization-of-held` for a fraction of the cost. But a
dashboard can only tell you the fleet is idle; it cannot act. The only safe action
on idle you must keep is to lend it. Because the warm floor is surge insurance you
keep regardless, lending is the sole way to recover the idle without giving up the
guarantee.

## 8. Break-even, stated plainly

The economic claim (ADR 0005) is:

```
training GPU-hours captured + surge readiness  ≥  held cost − commitment discounts
```

Solved honestly: commitment discounts and SLO-insurance value carry the
inequality; the priority stack (batch inference first, then R&D lending) and surge
readiness close the gap and, more importantly, make the left side observable and
adjustable. With batch inference on the stack, the left side is both larger and
more certain than a training-only reading suggests. Lending is the mechanism that
makes the left side measurable, not the mechanism that makes it large.

## 9. Levers (what the pilot lets you tune)

- **Lend-window width.** Longer window, more capture, but less warm-floor slack
  before the morning ramp.
- **Lendable fraction.** How much of the held book above the warm floor is offered;
  trades surge readiness for capture.
- **Batch-vs-training mix.** How much idle goes to revenue-priced batch inference
  versus training-substitute R&D. The highest-value knob on the stack.
- **Tier boundaries.** Where the realtime, batch, and R&D priorities sit, and which
  classes share a trust domain (scrub or no scrub).
- **Utilization floor.** The 70% target that triggers shrink, widen, or re-justify.
- **Commitment coverage.** The largest affordability lever, verified each ledger
  review.

## 10. Why not just…

The real alternatives a technical and financial room raises, answered:

- **…buy a FinOps dashboard?** It measures `utilization-of-held` and `idle-burn`
  for a fraction of the cost, but it can only report that the fleet is idle, not
  act on it. The only safe action on idle you must keep is to lend it; a dashboard
  leaves the idle burning.
- **…use MIG to partition each GPU in silicon?** MIG gives hardware-isolated slices
  on one physical GPU simultaneously, which helps for co-locating small inference
  with small experiments and sidesteps scrub latency. But MIG partitions are static
  and fragment the GPU: each slice is a fraction, so a large training run that wants
  a whole 8×H100 node with NVLink cannot use it, and repartitioning still drains
  the GPU. MIG fits the small co-location case, not the whole-fleet
  overnight-training case. Where it fits, use it; it is complementary, not a
  replacement.
- **…rent from a neocloud?** Let someone else hold the idle and rent
  dedicated-feeling capacity. A real option where available and compliant, but it
  moves the customer's data to a third party (a contractual problem for a B2B
  service under a DPA), and in a shortage the on-demand capacity you are counting
  on is exactly what is sold out.
- **…run one pool with Kueue priority preemption, no lending layer?** That works
  within a trust domain, and it is precisely how batch inference should soak idle.
  It does not work across the R&D boundary: preemption cannot checkpoint, drain,
  and scrub inside a latency SLA's budget, so training on the shared pool either
  risks the SLO or never yields safely. The lending layer exists for the case
  priority-preemption cannot cover.
- **…do nothing?** The status quo the pilot exists to end: $350k/month spent on
  faith, no `utilization-of-held`, no lever, no compliance proof. Doing nothing is
  not free; it is the blind cost, indefinitely.

## 11. Go / no-go for the pilot

A right-sized pilot (one region, the cheap profile the e2e harness already runs,
on the order of days and low-hundreds of dollars in cloud plus the platform team's
evaluation time) decides:

- **Go to production if:** lending runs safely at target scale (reclaim beats the
  ramp deadline, inference p95 holds, ledger zero-net-release, all demonstrated in
  the walking skeleton), and `utilization-of-held` trends toward the 70% floor once
  real batch-inference and training demand is pointed at it.
- **Shrink the book instead if:** utilization stays well below floor. The pilot has
  then earned its keep by telling you the hold is oversized. Note the shrink is
  itself irreversible in a shortage, so treat it as a deliberate, measured bet, not
  a costless win.
- **Kill if:** lending cannot hold the inference SLO under real load. It did in
  rehearsal; the pilot tests it under your traffic.

Either way the pilot converts a blind standing cost into a measured, governed, and
(for a B2B customer) provably-isolated one. That is the value; the lending revenue
is a bonus on top.

---

## Prerequisite — the platform must model three tiers

This case assumes the fleet can express three workload classes. The platform today
models **two** priority tiers (`inference-critical`, `training-preemptible`). The
batch-inference tier, preemptible but above training and same trust domain so it
needs no scrub, is a required increment before the batch-inference recovery in §4
is real. It is flagged here because the value case depends on it. It is a small
platform change (a third `PriorityClass` and a Kueue tier), not a redesign.
