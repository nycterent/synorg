#!/usr/bin/env bash
# validate.sh — the single validation loop (R10): identical locally and in CI.
# Diff-scoped by default so it stays in the seconds budget at ~100-service
# scale; FULL=1 renders the whole repo (nightly CI job).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FULL="${FULL:-0}"
RENDER_ONLY="${RENDER_ONLY:-0}"          # 1 = helm template only (CI rendered-diff job)
K8S_VERSION="${K8S_VERSION:-1.33.0}"
BUILD_DIR="$ROOT/build/rendered"
KUBECONFORM_CACHE="$ROOT/build/kubeconform-cache"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

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

CHANGED_FILE="$(mktemp)"
trap 'rm -f "$CHANGED_FILE"' EXIT
changed_paths >"$CHANGED_FILE"
CHANGED="$(cat "$CHANGED_FILE")"

# in_scope FILE — membership test against the changed set (single grep, no echo fork)
in_scope() { [ "$FULL" = "1" ] || grep -qxF "$1" "$CHANGED_FILE"; }

# Policy composition (R9/R6 admission rules) is armed whenever charts or policies
# changed, or under FULL — never in RENDER_ONLY. When armed it renders the whole
# chart+service surface and applies the REAL policies to that rendered output
# (section 3b), closing the gap where a chart could emit a pod the policies would
# reject at admission but offline validation never exercised.
POLICY_SCOPE=0
if [ "$RENDER_ONLY" != "1" ] && { [ "$FULL" = "1" ] || echo "$CHANGED" | grep -q '^charts/\|^policies/'; }; then
  POLICY_SCOPE=1
fi

# Charts to render: any chart whose dir is touched, or all under FULL=1.
charts_in_scope() {
  local chart
  for chart in charts/*/; do
    [ -f "$chart/Chart.yaml" ] || continue
    # Under FULL, or a policy-composition run, render every chart so the policy
    # check (3b) sees the whole rendered surface; otherwise only touched charts.
    if [ "$FULL" = "1" ] || [ "$POLICY_SCOPE" = "1" ] || grep -q "^${chart}" "$CHANGED_FILE"; then
      echo "$chart"
    fi
  done
}

# --- 1. Render + schema-check charts ---------------------------------------
rm -rf "$BUILD_DIR"                       # stale renders pollute the diff surface
mkdir -p "$BUILD_DIR" "$KUBECONFORM_CACHE"
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
    if [ "$RENDER_ONLY" != "1" ]; then
      kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
        -cache "$KUBECONFORM_CACHE" \
        -schema-location default -schema-location "$CRD_SCHEMAS" \
        "$out" || fail "$name/$vname: kubeconform schema violations"
    fi
    rendered_any=1
  done
done

# tracked + untracked files matching the given globs (single pass per call)
repo_files() {
  (git ls-files "$@"; git ls-files --others --exclude-standard "$@") 2>/dev/null | sort -u
}

# --- 2. Kubeconform on raw cluster manifests -------------------------------
if [ "$RENDER_ONLY" != "1" ]; then
manifests_in_scope() {
  local f
  for f in $(repo_files 'clusters/**/*.yaml' 'policies/**/*.yaml'); do
    case "$f" in clusters/*/services/*) continue ;; esac   # chart values, rendered below
    if in_scope "$f"; then echo "$f"; fi
  done
}
# Portable array fill (mapfile is Bash 4+; macOS ships Bash 3.2 and would fail
# here, skipping the schema check). while-read works on 3.2+.
MANIFESTS=()
while IFS= read -r _m; do MANIFESTS+=("$_m"); done < <(manifests_in_scope)
if [ "${#MANIFESTS[@]}" -gt 0 ]; then
  echo "kubeconform: ${#MANIFESTS[@]} manifest file(s)"
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" \
    -cache "$KUBECONFORM_CACHE" \
    -schema-location default -schema-location "$CRD_SCHEMAS" \
    "${MANIFESTS[@]}" || fail "cluster/policy manifest schema violations"
fi

# --- 2b. Service values render through the golden chart (real files) --------
# Rendered into $BUILD_DIR (not /dev/null) so the policy-composition check (3b)
# can apply the real policies to the actual rendered pods. Rendered when the file
# changed, or for the whole set on a policy-composition run.
for f in $(repo_files 'clusters/*/services/*.yaml'); do
  if in_scope "$f" || [ "$POLICY_SCOPE" = "1" ]; then
    out="$BUILD_DIR/service-$(basename "$f" .yaml).yaml"
    echo "render service values: $f"
    helm template svc charts/golden-service -f "$f" >"$out" \
      || fail "$f: does not satisfy the golden chart schema"
    rendered_any=1
  fi
done
fi  # RENDER_ONLY

# --- 3. Policy tests --------------------------------------------------------
if [ "$RENDER_ONLY" != "1" ] && { [ "$FULL" = "1" ] || echo "$CHANGED" | grep -q '^policies/\|^charts/'; }; then
  if ls policies/tests/*/kyverno-test.yaml >/dev/null 2>&1; then
    echo "kyverno test: policies/tests"
    kyverno test policies/tests --detailed-results || fail "kyverno policy tests failed"
  fi
fi

# --- 3b. Policy composition: real policies over rendered output (R9/R6) ------
# Section 3 tests policies against hand-written fixtures; section 1/2b render the
# charts and services. Neither applies the policies to that rendered output — the
# gap that lets a chart emit a pod the policies reject at admission. Close it:
# apply policies/kyverno to every rendered file. Kyverno auto-generates the
# pod-controller rules, so applying over rendered Deployments/Jobs reproduces the
# admission verdict a cluster would give. `kyverno apply` exits non-zero on any
# violation.
if [ "$POLICY_SCOPE" = "1" ]; then
  shopt -s nullglob
  RENDERED_FILES=("$BUILD_DIR"/*.yaml)
  shopt -u nullglob
  if [ "${#RENDERED_FILES[@]}" -gt 0 ]; then
    echo "kyverno apply: policies/kyverno over ${#RENDERED_FILES[@]} rendered file(s)"
    RESOURCE_ARGS=()
    for rf in "${RENDERED_FILES[@]}"; do
      RESOURCE_ARGS+=(--resource "$rf")
    done
    kyverno apply policies/kyverno "${RESOURCE_ARGS[@]}" \
      || fail "rendered output violates a Kyverno policy — a rendered pod would be rejected at admission. Fix the chart/values that emits it, never the policy."
  fi
fi

# --- 4. Rendered diff (PR surface) -----------------------------------------
if [ "$rendered_any" = "1" ] && [ "${RENDER_DIFF:-1}" = "1" ]; then
  echo "rendered output in $BUILD_DIR (CI posts the diff against base)"
fi

echo "VALIDATE OK"
