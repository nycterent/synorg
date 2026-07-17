#!/usr/bin/env bash
# demo.sh — a narrated, read-only walk through what this repo proves offline.
# No cloud, no cluster, no mutations: it renders charts, shows the policy plane
# accepting a good pod and rejecting a bad one, and runs the env-spec bridge.
# The live platform (GPU lending, Kueue preemption, ArgoCD sync) needs a real
# EKS cluster — see runbooks/ for that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

b() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }        # section banner
note() { printf '\033[0;90m%s\033[0m\n' "$1"; }             # dim aside
need() { command -v "$1" >/dev/null 2>&1 || { echo "demo needs '$1' (brew install $1)"; exit 1; }; }

need helm; need kyverno; need python3

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

b "1. The deploy interface — one golden chart, values are the whole API (R4)"
note "Rendering the example customer-data inference service through charts/golden-service:"
helm template demo charts/golden-service -f clusters/pilot/services/example-inference.yaml > "$WORK/svc.yaml"
note "Its scheduling contract (customer-data ⇒ warm floor only, never lendable):"
grep -A6 'tolerations:' "$WORK/svc.yaml" | sed 's/^/    /'

b "2. The policy plane ACCEPTS the correct pod (R9 tenancy isolation)"
note "kyverno apply — real policies over the rendered output:"
kyverno apply policies/kyverno --resource "$WORK/svc.yaml" 2>/dev/null | grep -E 'pass:|fail:' || true

b "3. The policy plane REJECTS a customer-data pod that tolerates lendable"
note "Same pod, but flip its toleration warm-floor -> lendable (the P0 the review caught):"
sed 's#pool.synorg.io/warm-floor#pool.synorg.io/lendable#' "$WORK/svc.yaml" > "$WORK/bad.yaml"
if kyverno apply policies/kyverno --resource "$WORK/bad.yaml" 2>/dev/null | grep -E 'pass:|fail:'; then :; fi
note "tenancy-guard denies it: a lent node can be reclaimed and scrubbed for R&D,"
note "so customer data must never land there. This is why make validate composes"
note "rendered chart output against the real policies, not just fixtures."

b "4. The migration bridge — env-spec in, golden-chart values out (R11, zero human translation)"
note "Translating a legacy env-spec fixture:"
python3 tools/env-spec-bridge/bridge.py tools/env-spec-bridge/fixtures/inference-vision.envspec.yaml | sed 's/^/    /'

b "Done — that is the offline-provable surface"
note "Full gate:            make validate        (helm + kubeconform + kyverno + policy composition)"
note "Bridge test suite:    python3 -m pytest tools/env-spec-bridge/ -q"
note "Live platform:        needs a real EKS cluster (U3+); see runbooks/ and docs/explanation/."
