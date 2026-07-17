#!/usr/bin/env bash
# validate.sh — the single validation loop (R10): identical locally and in CI.
# Diff-scoped by default so it stays in the seconds budget at ~100-service
# scale; FULL=1 renders the whole repo (nightly CI job).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FULL="${FULL:-0}"
K8S_VERSION="${K8S_VERSION:-1.33.0}"
BUILD_DIR="$ROOT/build/rendered"

fail() { echo "VALIDATE FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not installed — install it (brew install $1) so local validation matches CI"; }

need helm
need kubeconform
need kyverno

# --- Scope: changed paths vs merge-base, or everything under FULL=1 -------
changed_paths() {
  if [ "$FULL" = "1" ]; then
    git ls-files
  else
    local base
    base="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "")"
    if [ -n "$base" ]; then
      git diff --name-only "$base"...HEAD
      git diff --name-only                          # unstaged
      git diff --name-only --cached                 # staged
      git ls-files --others --exclude-standard      # untracked
    else
      git ls-files
      git ls-files --others --exclude-standard
    fi
  fi | sort -u
}

CHANGED="$(changed_paths)"

# Charts to render: any chart whose dir is touched, or all under FULL=1.
charts_in_scope() {
  local chart
  for chart in charts/*/; do
    [ -f "$chart/Chart.yaml" ] || continue
    if [ "$FULL" = "1" ] || echo "$CHANGED" | grep -q "^${chart}"; then
      echo "$chart"
    fi
  done
}

# --- 1. Render + schema-check charts ---------------------------------------
mkdir -p "$BUILD_DIR"
rendered_any=0
for chart in $(charts_in_scope); do
  name="$(basename "$chart")"
  ci_values=("$chart"ci/*.yaml)
  [ -e "${ci_values[0]}" ] || fail "$name: no ci/ test values — every chart ships CI values"
  for values in "${ci_values[@]}"; do
    vname="$(basename "$values" .yaml)"
    out="$BUILD_DIR/$name-$vname.yaml"
    echo "render: $name ($vname)"
    helm template "$name" "$chart" -f "$values" >"$out" \
      || fail "$name/$vname: helm template failed (see error above — schema violations name the field)"
    kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$out" || fail "$name/$vname: kubeconform schema violations"
    rendered_any=1
  done
done

# --- 2. Kubeconform on raw cluster manifests -------------------------------
manifests_in_scope() {
  local f
  for f in $( (git ls-files 'clusters/**/*.yaml' 'policies/**/*.yaml'; git ls-files --others --exclude-standard 'clusters/**/*.yaml' 'policies/**/*.yaml') 2>/dev/null | sort -u); do
    if [ "$FULL" = "1" ] || echo "$CHANGED" | grep -qx "$f"; then echo "$f"; fi
  done
}
mapfile -t MANIFESTS < <(manifests_in_scope)
if [ "${#MANIFESTS[@]}" -gt 0 ]; then
  echo "kubeconform: ${#MANIFESTS[@]} manifest file(s)"
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "${MANIFESTS[@]}" || fail "cluster/policy manifest schema violations"
fi

# --- 3. Policy tests --------------------------------------------------------
if [ "$FULL" = "1" ] || echo "$CHANGED" | grep -q '^policies/\|^charts/'; then
  if ls policies/tests/*/kyverno-test.yaml >/dev/null 2>&1; then
    echo "kyverno test: policies/tests"
    kyverno test policies/tests --detailed-results || fail "kyverno policy tests failed"
  fi
fi

# --- 4. Rendered diff (PR surface) -----------------------------------------
if [ "$rendered_any" = "1" ] && [ "${RENDER_DIFF:-1}" = "1" ]; then
  echo "rendered output in $BUILD_DIR (CI posts the diff against base)"
fi

echo "VALIDATE OK"
