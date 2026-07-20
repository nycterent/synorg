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
command -v python3    >/dev/null || { echo "need python3 (white-bg injection)"; exit 1; }

# inject_white_bg SVG — the diagrams are black-ink-on-transparent (dvisvgm/
# pdftocairo output); GitHub's dark theme renders them invisible. Insert a
# viewBox-sized white rect right after the opening <svg> so every committed SVG
# reads on a light card in both themes. Idempotent, and re-applied on every
# build (pdftocairo regenerates the file and drops any prior rect).
inject_white_bg() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
if 'data-bg-injected' in t: sys.exit(0)
m = re.search(r'viewBox="([\d.\-]+) ([\d.\-]+) ([\d.\-]+) ([\d.\-]+)"', t)
if not m: sys.exit("  no viewBox in "+p.name)
x, y, w, h = map(float, m.groups()); mx, my = w*0.02, h*0.04
rect = f'<rect data-bg-injected="1" x="{x-mx}" y="{y-my}" width="{w+2*mx}" height="{h+2*my}" fill="#ffffff"/>'
p.write_text(re.sub(r'(<svg\b[^>]*>)', r'\1'+rect, t, count=1))
PY
}

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
  inject_white_bg "$OUT/$name.svg"
  built=$((built+1))
done

echo "built $built diagram(s) -> $OUT"
