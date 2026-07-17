# Runbook: GPU node scrub-on-return

Executable playbook for returning a lent GPU node to the prod-tolerable pool by
**discarding the instance and recovering a fresh one** — never by cleaning the
node in place. Scrub is a hard trust-domain reset (KTD3, Assumption 6): between
arbitrary R&D training and customer-data inference, GPU device memory must not
survive, so the scrub is a `nodeclaim` deletion that terminates the EC2 instance.
The returning node is a brand-new instance booting a fresh AMI — fresh VRAM by
construction.

Normally the U8 lending-controller runs this automatically at reclaim time; this
runbook is the manual/verification path and the ground truth the controller
implements. **Verify before untaint at every step; a node is never prod-
schedulable between lend and completed scrub.**

Preconditions: the pilot cluster + Karpenter are live (U3), the node carries the
`lending.synorg.io/lent=true:NoSchedule` taint (it is a returning lent node), and
its training pods have drained under the 120 s grace (KTD12).

## Variables

```bash
export NODE=ip-10-0-0-0.eu-west-1.compute.internal   # the returning lent node
export REGION=eu-west-1
```

## Step 0 — Record the OLD instance identity (the thing that must NOT persist)

```bash
OLD_INSTANCE=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}')   # aws:///<az>/<instance-id>
OLD_NODECLAIM=$(kubectl get nodeclaim -o json \
  | jq -r ".items[] | select(.status.nodeName==\"$NODE\") | .metadata.name")
echo "old instance: $OLD_INSTANCE   nodeclaim: $OLD_NODECLAIM"
```

Record `OLD_INSTANCE` — Step 4 asserts the returned node has a **different**
instance-id. Equal instance-id ⇒ VRAM was not reset ⇒ **abort, do not untaint**.

## Step 1 — Confirm drained and cordon

```bash
# Training already evicted under grace; confirm no GPU pods remain, then cordon
# so nothing schedules onto the doomed instance.
kubectl get pods --all-namespaces --field-selector "spec.nodeName=$NODE" \
  -o json | jq -r '.items[] | select(.spec.containers[].resources.requests["nvidia.com/gpu"]) | .metadata.name'
# Require: empty output (no GPU pods). Then:
kubectl cordon "$NODE"
```

## Step 2 — Scrub: delete the NodeClaim (terminates the EC2 instance)

```bash
kubectl delete nodeclaim "$OLD_NODECLAIM"
# Karpenter drains remaining system pods and terminates the instance. Confirm
# the EC2 instance reaches TERMINATED (the VRAM-bearing hardware is gone):
aws ec2 describe-instances --region "$REGION" \
  --instance-ids "${OLD_INSTANCE##*/}" \
  --query 'Reservations[0].Instances[0].State.Name'
# Require: "shutting-down" then "terminated". This is the discard-and-recover
# boundary — nothing carries across it.
```

## Step 3 — Recover: a fresh instance boots from a fresh AMI

Karpenter provisions a replacement from the same reserved capacity (the pool
still has demand/limits). Wait for the new node to register Ready.

```bash
# Watch for the replacement nodeclaim + node to go Ready:
kubectl get nodeclaims -w        # a NEW nodeclaim appears, Launched -> Registered -> Initialized
kubectl get nodes -l pool.synorg.io/name=lendable -w
NEW_NODE=<new node name once Ready>
NEW_INSTANCE=$(kubectl get node "$NEW_NODE" -o jsonpath='{.spec.providerID}')
```

## Step 4 — Verify (new instance-id, clean DCGM, taints correct)

```bash
# 4a. Fresh instance — VRAM reset is proven by a NEW instance-id.
echo "old=$OLD_INSTANCE new=$NEW_INSTANCE"
# Require: NEW_INSTANCE != OLD_INSTANCE. Equal ⇒ ABORT (no reset happened).

# 4b. DCGM health clean on the new node (no ECC/XID faults on fresh boot).
kubectl get pods -n observability -l app=dcgm-exporter \
  --field-selector "spec.nodeName=$NEW_NODE"
# Query dcgm_gpu_health / XID error counters == 0 for this node (see U9
# recording rules). Any fault ⇒ route to gpu-node-quarantine.md, do not return.

# 4c. Taints correct: the fresh node must NOT carry lending.synorg.io/lent.
kubectl get node "$NEW_NODE" -o jsonpath='{.spec.taints}'
# Require: base pool.synorg.io/lendable taint only; NO lending.synorg.io/lent.
```

## Step 5 — Untaint to prod (return-to-service)

Only after Step 4 passes. Returning to prod = removing any lent taint so the
node is prod-tolerable; the controller emits `NodeReturnedToProd`.

```bash
kubectl taint node "$NEW_NODE" lending.synorg.io/lent- 2>/dev/null || true
kubectl uncordon "$NEW_NODE"
```

Record the return-to-service duration (Step 2 delete → Step 5 uncordon) as a
sample for the `nodeReturnToServiceBudgetSeconds` p95 (KTD12); this feeds the
wave lead time in schedule.yaml.

## Abort semantics

- `NEW_INSTANCE == OLD_INSTANCE` (Step 4a) → **abort, do not untaint.** The
  instance was not replaced; VRAM was not reset. Open an incident.
- Any DCGM fault on the fresh node (Step 4b) → this is not a return, it is a
  quarantine. Go to `gpu-node-quarantine.md`.
- Never untaint a node that still carries `lending.synorg.io/lent` or that failed
  any verify step. The invariant is trust reset, not schedule progress.
