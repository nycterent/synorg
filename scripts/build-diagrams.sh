#!/usr/bin/env bash
# build-diagrams.sh — compile every diagrams/*.tex TikZ source to a committed SVG
# under docs/assets/diagrams/. tectonic fetches LaTeX packages on first run and
# caches them; pdftocairo (poppler) converts PDF -> SVG. Only needed to
# REGENERATE diagrams — the site and its CI serve the committed SVGs and never
# need a LaTeX toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v tectonic   >/dev/null || { echo "need tectonic (brew install tectonic)"; exit 1; }
command -v pdftocairo >/dev/null || { echo "need pdftocairo (brew install poppler)"; exit 1; }

SRC="$ROOT/diagrams"
OUT="$ROOT/docs/assets/diagrams"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

shopt -s nullglob
built=0
for tex in "$SRC"/*.tex; do
  name="$(basename "$tex" .tex)"
  case "$name" in _*) continue ;; esac         # _style.tex etc are includes, not diagrams
  echo "diagram: $name"
  # Compile in the source dir so \input{_style} resolves, output PDF to TMP.
  ( cd "$SRC" && tectonic --outdir "$TMP" -c minimal "$tex" ) >/dev/null 2>"$TMP/$name.log" \
    || { echo "  tectonic failed:"; tail -5 "$TMP/$name.log"; exit 1; }
  pdftocairo -svg "$TMP/$name.pdf" "$OUT/$name.svg" \
    || { echo "  pdftocairo failed for $name"; exit 1; }
  built=$((built+1))
done

echo "built $built diagram(s) -> $OUT"
