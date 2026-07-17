# Kueue scheduling layer (U6)

Layered reclaim, two mechanisms for one guarantee — *inference always wins,
training soaks the rest* (R1, KTD6):

1. **Quota curve = planned reclaim.** `training-borrow` (nominal 0) borrows the
   lendable pool from the `gpu-lending` cohort up to a `borrowingLimit` curve —
   the git-scheduled aggregate of inference demand (`platform-lendable` owns the
   quota). U8 shrinks the curve ahead of the morning ramp; Kueue preempts
   training to fit, inside the 120 s checkpoint contract (KTD12).
2. **PriorityClass = emergency layer.** When demand outruns the curve, pending
   `inference-critical` pods preempt `training-preemptible` node-level via
   kube-scheduler — no queue on the render path (serving is never Kueue-admitted).
