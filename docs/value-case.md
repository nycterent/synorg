# Value case — why run the pilot

For the Head of Platform deciding whether synorg earns a real pilot. The honest
version: lending is not a payback machine, and pretending otherwise fails the
first finance review. The value is measured de‑risking of a large standing cost
you are already paying.

All dollar figures below are **illustrative**, computed from the pilot held book
in ADR 0005 at eu‑west‑1 on‑demand rates. Swap your own fleet, window, and
training price — the arithmetic and its levers are what matter, not these
specific numbers.

## 1. The cost being attacked

Scarce GPU capacity is rented and deliberately never descaled (released capacity
may not return). Two bills land every month:

- **Held‑fleet burn** — the reserved book bills at full on‑demand whether used or
  not. The pilot book (4× p5.48xlarge, 8× g6e.12xlarge, 3× g7e.2xlarge) is on the
  order of **$350k/month** of standing burn (ADR 0005).
- **Separately‑bought training** — R&D trains at 100% on its own GPUs while the
  inference fleet sits ~90% idle overnight. You pay the availability premium on
  the held fleet *and* full price for training capacity — the double‑pay.

## 2. What lending directly recovers — be honest, it's a slice

Lending captures overnight‑idle **lendable** GPUs (the g6e/g7e portion — the p5
warm floor is inference insurance and is never lent) for training that would
otherwise be bought separately. From the pilot book, ~35 lendable GPUs × the
8.5‑hour lend window:

| Utilization of the lendable window | Training GPU‑hours captured /mo | Value recovered /mo | Share of the $350k burn |
| --- | --- | --- | --- |
| 50% | ~4,500 | ~$7–11k | ~2–3% |
| 70% (the ADR 0005 floor) | ~6,250 | ~$9–16k | ~3–5% |
| 90% | ~8,000 | ~$12–20k | ~3–6% |

(Training price band $1.5–2.5/GPU‑hr, L40S‑class.) **Lending does not pay for the
fleet.** Anyone who claims it does hasn't done this arithmetic.

### What this model does not capture — and why the pilot exists

The table above is a **single‑region, uniform‑workload floor of understanding**,
not a forecast. Three drivers dominate the real answer, and none are modeled here
because none are knowable without running it:

- **Inference demand shape.** "~90% idle overnight" is an average, not a
  guarantee. Real inference load is lumpy — spikes, timezone spread, launch
  events. Every hour inference actually needs the lendable pool is an hour it
  can't be lent. The clean 22:00–06:30 window is an upper bound on availability.
- **R&D backlog alignment.** The 70% utilization number *assumes R&D always has
  overnight work to fill 35 lent GPUs.* If the training backlog is thin, bursty,
  or deadline‑misaligned with the window, `utilization‑of‑held` craters and the
  recovery with it. This is the single largest swing factor, and it is a property
  of *your* R&D org, not the platform.
- **Regional arbitrage.** The core rationale (ADR 0001) is that GPU availability,
  instance families, and spot/reservation dynamics differ *between regions* — so
  work is placed where availability is. This model is single‑region and captures
  none of it: follow‑the‑sun inference peaks, R&D data gravity that may not
  co‑locate with idle capacity, MultiKueue cross‑region dispatch. The multi‑region
  value could be materially higher or lower; the arithmetic here does not reach it.

This is precisely why the point estimate is not the pitch. **The pilot's job is to
measure the joint distribution of (inference demand × R&D backlog × regional
availability) that this model assumes away** — turning a floor‑of‑understanding
into a real one. A value case that claimed to already know these numbers would be
the thing to distrust.

## 3. What actually justifies the held book

The fleet is affordable for reasons lending only *supplements*:

- **SLO insurance.** p5/H100‑class capacity cannot be provisioned on demand; the
  warm floor is bought so customer inference has guaranteed render‑start latency.
  That's the primary justification, and it exists with or without lending.
- **Commitment discounts.** Savings Plans / RIs stack on top of capacity
  reservations (ADR 0005). Holding without them pays for insurance twice; the
  ledger review verifies coverage. This is where most of the "affordability"
  comes from.
- **Lending margin.** The single‑digit‑% recovery above — real, measured, but
  marginal against the burn.

Read together: the hold is insurance you're paying anyway, made cheaper at the
margin by lending, and — critically — **now measured**.

## 4. The pilot's real value: de‑risking a blind $350k/month decision

This is the line that greenlights the pilot. Today the $350k/month held cost is
spent **blind** — nothing measures whether it earns its keep. synorg makes lending
*safe* (the walking skeleton proved lend → reclaim → scrub → rejoin with
zero‑net‑release and inference latency held), which turns two numbers into
actionable levers:

- **`utilization‑of‑held`** — GPU‑hours allocated ÷ held, per pool. Below the 70%
  floor for a rolling month → the standing options are **shrink the reservation,
  widen the lending window, or re‑justify the sizing in writing.**
- **`idle‑burn`** — $/day of held‑but‑unallocated capacity at on‑demand rates.
  The premium the lending machine is offsetting, tracked instead of assumed.

**The pilot's payoff is not the ~$12k/month of lending revenue. It is that you
stop paying $350k/month on faith and start paying it on evidence** — with a lever
(safe lending) to act on the evidence. De‑risking a decision that size is worth
far more than the marginal recovery.

## 5. Break‑even, stated plainly

The economic claim (ADR 0005) is:

```
training GPU‑hours captured + surge readiness  ≥  held cost − commitment discounts
```

Solved honestly: **commitment discounts + SLO‑insurance value carry the
inequality; lending margin + surge readiness close the remaining gap and, more
importantly, provide the measurement that keeps the whole book honest over time.**
Lending is the mechanism that makes the left side *observable and adjustable*, not
the mechanism that makes it large.

## 6. Levers (what the pilot lets you tune)

- **Lend‑window width** — longer window, more capture, but less warm-floor slack
  before the morning ramp.
- **Lendable fraction** — how much of the held book above the warm floor is
  offered; trades surge readiness for capture.
- **Utilization floor** — the 70% target that triggers shrink/widen/re‑justify.
- **Commitment coverage** — the largest affordability lever, verified each ledger
  review.

## 7. Why not just…

The first questions in the room, answered:

- **…train on pure spot?** Spot is cheap but it's *someone else's* preemption
  clock — AWS reclaims on its schedule, not before your morning ramp, so you
  can't guarantee inference headroom when you need it. And it does nothing about
  the held inference fleet, which still sits idle overnight. You'd have cheap
  training and an unmeasured $350k burn side by side. (ADR 0005 rejects
  hold‑warm‑floor + pure‑spot for exactly this — it guts surge readiness.)
- **…buy more dedicated GPUs for training?** That widens the double‑pay into a
  triple‑pay: held inference + existing training + more training, with the idle
  burn untouched. It scales cost linearly and never asks whether the capacity you
  already hold is earning its keep.
- **…use Karpenter + Kueue without the lending layer?** They provision and admit,
  but nothing makes lend → reclaim *safe against the inference SLO* — draining
  before the ramp, scrubbing to a genuinely new instance, proving zero‑net
  capacity release. That orchestration, and the measurement it enables, is the
  product; the schedulers are ingredients.
- **…do nothing?** That's the status quo the pilot exists to end: $350k/month
  spent on faith, no `utilization‑of‑held`, no lever. "Do nothing" is not free —
  it's the blind cost, indefinitely.

## 8. Go / no‑go for the pilot

A right‑sized pilot (one region, the cheap profile the e2e harness already runs —
on the order of days and low‑hundreds of dollars in cloud, plus the platform
team's evaluation time) decides:

- **Go to production if:** lending runs safely at target scale (reclaim beats the
  ramp deadline, inference p95 holds, ledger zero‑net‑release — all demonstrated
  in the walking skeleton), **and** `utilization‑of‑held` trends toward the 70%
  floor once real training backlog is pointed at it.
- **Shrink the book instead if:** utilization stays well below floor — the pilot
  has then earned its keep by telling you the hold is oversized, which is a
  win, not a failure.
- **Kill if:** lending can't hold the inference SLO under real load (it did in
  rehearsal; the pilot tests it under your traffic).

Either way the pilot converts a blind standing cost into a measured one. That is
the value — the lending revenue is a bonus on top.
