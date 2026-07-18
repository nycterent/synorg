---
hide:
  - toc
---

# Kernel-idle is not allocation-idle — and lending only fixes one of them { .tufte }

**Date:** 2026-07-17
**Context:** GPU utilization instrumentation and the lending thesis
(`eks-platform.prd` Success Metric 2, plan Assumption 2 / Open Question 2).

## The distinction, and why it is load-bearing

"The GPU fleet is ~90% idle" has two entirely different meanings with two
entirely different fixes:

- **Allocation-idle** — the node is *not running anything* (whole inference nodes
  sitting empty at night). Recoverable by **lending** the node to another
  workload. This is what the whole platform targets.
- **Kernel-idle** — the node *is allocated and running*, but the GPU spends a
  large fraction of wall-clock not executing kernels (stalled on I/O, host
  post-processing, small batches, poor overlap). Lending cannot touch this — the
  node is already busy. Only the **workload** can recover it.

Conflating the two is the trap: if the "90% idle" is actually kernel-idle,
building a lending platform recovers little, because the idle is *inside* the
running workload, not between workloads.

## External evidence (Synthesia on EC2 G7e)

AWS Architecture Blog, *How Synthesia optimizes generative AI video inference on
Amazon EC2 G7e instances*
(<https://aws.amazon.com/blogs/architecture/how-synthesia-optimizes-generative-ai-video-inference-on-amazon-ec2-g7e-instances/>):

- Latent-diffusion video inference on **G7e** (NVIDIA RTX PRO 6000 Blackwell,
  96 GB). The VAE decoder was bottlenecked by **saving decoded frames to
  storage**, stalling the GPU.
- Measured **kernel utilization 82%** while the GPU was fully allocated — 18%
  left on the floor to I/O stalls, invisible to any allocation-based metric.
- Fix was purely app-side — an **Asynchronous Frame Generation Pipeline**: two
  CUDA streams (compute + a dedicated copy stream), pinned-memory buffers, a
  worker thread — overlapping GPU compute, device→host transfer, and host I/O.
- Result: **82% → 99.9%** kernel utilization, **8.2%** lower decode latency,
  ~**$896 per 1,000 GPU-hours** saved (g7e.2xlarge, $3.36/GPU-hr, us-east-2),
  no weight or quality change.

## What this changes for us

1. **The allocation-vs-kernel-idle split in the evidence plane (U9) is the right
   instrumentation, and it is not optional.** `gpu_allocation_idle` vs
   `gpu_kernel_util` (DCGM) is exactly how you tell which idle you have. Success
   Metric 2 ("kernel utilization reported separately per workload class") is
   validated.
2. **Assumption 2's revisit trigger is sharpened:** kernel-idle-under-allocation
   routes to a workload workstream (batching, right-sizing, async I/O overlap),
   **never** to more lending.
3. **G7e belongs in the held-fleet candidates** (added to the ODCR variables)
   and the quarterly $/GPU-hour review — it is the memory-heavy inference target
   the PRD scarcity example already names.
4. **Storage bandwidth is a first-class resource.** Frame-save I/O stalling the
   GPU is the same coupling that hits the checkpoint store (U7); during a lending
   window, inference frame-output and training checkpoints can contend on shared
   storage. Size for it.
5. **Pinned-memory fast D2H is a concrete tactic for the 120 s final-checkpoint
   residual** (`runbooks/training-onboarding.md`): pinned buffers + a dedicated
   copy stream are how a large model gets its final checkpoint out before
   SIGKILL, turning "best-effort" into a technique.
