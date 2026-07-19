# Validate the platform on your laptop

By the end of this lesson you will have run the platform's validation loop on
your own machine and watched its policy plane reject an unsafe workload — no AWS
account, no cluster, nothing to clean up. Follow every step in order; each one
is meant to succeed exactly as written.

This is a lesson, not a reference. It does not explain *why* the platform is
built this way (that is [why-lending](../explanation/why-lending.md)) or how to
carry out a real operation (that is the [runbooks](../../runbooks/service-migration.md)). It only
gets you to your first green run.

## Before you start

You need three command-line tools. Install them, then confirm each prints a
version:

```bash
brew install helm kubeconform kyverno   # macOS; use your package manager otherwise
helm version --short
kubeconform -v
kyverno version
```

You also need Python 3, which you almost certainly already have:

```bash
python3 --version
```

Now move into the repository you cloned:

```bash
cd synorg
```

You are ready.

## Step 1 — Take the guided tour

Run the demo. It renders a real service, exercises the policy plane, and
translates a legacy config — all read-only.

```bash
make demo
```

Watch the output scroll past. You will see four labelled sections. Do not worry
about the detail yet; you are about to look at the important part deliberately.

## Step 2 — Watch the policy plane accept a correct workload

In the demo output, find the section titled **"The policy plane ACCEPTS the
correct pod"**. It shows this line:

```
pass: 2, fail: 0, warn: 0, error: 0, skip: 1
```

Zero failures. The service you just rendered is allowed to run. Good — that is
the normal case.

## Step 3 — Watch the policy plane reject an unsafe workload

Now find the next section, **"The policy plane REJECTS a customer-data pod that
tolerates lendable"**. It shows:

```
pass: 1, fail: 0, warn: 0, error: 0, skip: 1   ← count before
pass: 1, fail: 1, ...                           ← one failure now
```

One failure. The demo took the same customer-data service and let it schedule
onto the *lendable* GPU pool — nodes that get handed to R&D training at night.
The policy plane refused it. You just saw the platform's core safety rule
enforced against rendered output, not a hand-written test.

## Step 4 — Run the full gate

The demo is a tour. The real check every change must pass is one command:

```bash
make validate
```

Watch it render the charts, schema-check every manifest, run the policy test
suite, and finish with:

```
VALIDATE OK
```

That is the exact command the CI pipeline runs, byte for byte. A change that
makes this print `VALIDATE OK` on your laptop passes CI for the same reason.

## What you did

You installed the toolchain, ran the platform's validation loop, and watched its
policy plane both accept a safe workload and reject an unsafe one — the guarantee
the whole deploy path is built around.

## Where to go next

- To understand *why* the platform lends GPUs and why that rejection rule
  exists, read [why-lending](../explanation/why-lending.md).
- To carry out a real operation against a cluster, the how-to guides — for
  example [migrate a service](../../runbooks/service-migration.md) — are the
  executable runbooks.

*(An "add your first service" lesson is planned — see `docs/TODO-docs.md`, T2.)*
