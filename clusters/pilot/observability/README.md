# Verification notes — observability manifests

`recording-rules.yaml`'s header comment promises the `.spec.groups` body is
"promtool-checkable by extracting it (see the directory's verification notes)".
This file is those notes.

## Why extraction is needed

`recording-rules.yaml` is a `PrometheusRule` CRD. `kubeconform` (run by
`scripts/validate.sh` sections 1/2) validates that envelope — it checks the
CRD's own schema, not the PromQL inside it. Every `expr:` field is an opaque
string as far as kubeconform is concerned, so a syntactically broken rule
still passes schema validation.

`promtool check rules` is the tool that actually parses PromQL, but it expects
a plain Prometheus rules file — a document with a top-level `groups:` key —
not a `PrometheusRule` CRD wrapped in `apiVersion`/`kind`/`metadata`/`spec`.

## What `scripts/validate.sh` does (U9)

For every `*.yaml` file in this directory whose `kind` is `PrometheusRule`
and that is in scope for the current run, `validate.sh`:

1. Extracts `.spec.groups` with `yq '{"groups": .spec.groups}' <file>` into its
   own file under a per-run temp directory, named after the source file's
   basename, so groups from different manifests are never concatenated into
   the same document.
2. Runs `promtool check rules` over the resulting file(s).

A missing `promtool` binary fails the preflight (`need promtool`) with an
install hint, the same way `helm`, `kubeconform`, and `kyverno` do.

## Running it by hand

```sh
yq '{"groups": .spec.groups}' clusters/pilot/observability/recording-rules.yaml \
  | promtool check rules /dev/stdin
```

Or, to check a file on disk:

```sh
yq '{"groups": .spec.groups}' clusters/pilot/observability/recording-rules.yaml \
  > /tmp/recording-rules.rules.yaml
promtool check rules /tmp/recording-rules.rules.yaml
```

`promtool check rules` reports the offending group and rule name (e.g.
`group "criterion3-cost", rule 1, "gpu_hour_cost:usd": could not parse
expression: ...`) so a broken `expr` is identifiable directly from its output.

## Scope

This check only covers `.spec.groups` — the recording-rule PromQL. It does not
evaluate the queries against live metrics (that requires a running Prometheus)
and it does not check `slo-definitions.yaml`'s queries, since that manifest is
a plain `ConfigMap`, not a `PrometheusRule`, and its `query:` fields reference
the recording-rule names checked here rather than defining new rule groups.
