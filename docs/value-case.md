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

## 7. Go / no‑go for the pilot

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
