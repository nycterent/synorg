# SLO Catalog

> **Generated view — do not edit by hand.** This table mirrors
> `clusters/pilot/observability/slo-definitions.yaml` (the machine-readable source
> of truth agents read). Every row here corresponds one-to-one to an entry under
> `slos:` in that ConfigMap. When you change the SLO config, update this table in
> the same PR — they MUST stay in sync (U9: the catalog is the human-readable
> projection of the config, never a second source of truth).

Each SLO is evaluated by running its PromQL query and comparing the scalar result
against the target with the given comparison. The recording rules the queries
reference live in `clusters/pilot/observability/recording-rules.yaml`.

| SLO | Criterion | Comparison | Target | Unit | PromQL query |
|---|---|---|---|---|---|
| `render_start_p95` | 1 | `<=` | 2.0 | seconds | `render_start_seconds:p95` |
| `render_start_p95_reclaim_window` | 1 | `<=` | 2.0 | seconds | `render_start_seconds:p95:reclaim_window` |
| `training_lost_work_max` | 2 | `<=` | 300 | seconds | `max(training_checkpoint_lost_seconds)` |
| `gpu_kernel_util_floor` | 2 | `>=` | 0.35 | ratio | `avg(gpu_kernel_util:ratio)` |
| `gpu_attribution_complete` | 6 | `>=` | 1.0 | ratio | `sum(team:gpu_allocated:sum) / clamp_min(sum(kube_pod_container_resource_requests{resource="nvidia_com_gpu"}), 1)` |
| `capacity_unmet_ratio` | 8 | `<=` | 0.10 | ratio | `max(capacity_unmet:ratio)` |
| `reclaimed_hours_served` | 3 | `>=` | 1 | gpus | `reclaimed_hours_served:gpus` |
| `pr_to_converged_p95` | 5 | `<=` | 900 | seconds | `pr_to_converged_seconds:p95` |
| `auto_approved_ratio` | 5 | `>=` | 0.80 | ratio | `auto_approved:ratio` |

## Notes

- **Targets are placeholders pinned during rollout.** `render_start_*` (2.0 s),
  `training_lost_work_max` (300 s = the KTD12 ≤5-min budget), and the flow targets
  are the load-bearing ones; the rest are shaping thresholds.
- **Attribution completeness** reads 1.0 exactly when there is no unattributed
  GPU remainder — U5 denies unlabeled GPU pods, so the ratio can only fall below
  1.0 if enforcement regresses.
- **Scarcity is not failure.** `capacity_unmet_ratio` is surfaced as evidence for
  the fleet-shaping loop (KTD5); a breach means "ask for more held capacity",
  not "page someone".
- **`training_lost_work_max`** reads a raw game-day series
  (`training_checkpoint_lost_seconds`); it is the U10 pass gate expressed as an
  SLO so the harness and the read-API agree on the number.
- **Evidence signals with no target (U6, R28).** `borrower:gpu_borrowed:sum`,
  `borrower:admission_wait_seconds:p95` (both per `cluster_queue`, so a second
  borrower class registers free), `held:gpu_capacity:sum`, and
  `held:lendable_utilization:ratio` are decision inputs, not pass/fail SLOs. They
  feed R2's curve-vs-leases graduation trigger and the keep-or-shrink call on the
  held book; their thresholds are pinned in pass 2 when the governor lands, not
  here. Rising admission wait under a filled curve is the signal that argues for
  lease objects.
- **RTS stage series (U3, R5).** `rts_reimage_seconds:p95`,
  `rts_orchestration_seconds:p95`, and `rts_attest_seconds:p95` (declared-absent
  until R13) decompose return-to-service. Pass 1 stands them up; the governor
  that consumes them is pass 2.
