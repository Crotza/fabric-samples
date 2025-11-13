#!/bin/bash
set -euo pipefail

CD="${1:-.}"

# Ensure the directory exists
if [[ ! -d "$CD" ]]; then
  echo "Folder not found: $CD"
  exit 1
fi

echo "Exporting pprof artifacts from: $CD"
echo

export_one() {
  local in="$1"
  local base="${in%.*}"
  local name
  name="$(basename "$base")"

  echo "-> $name"

  # Default callgraph (SVG/PNG)
  go tool pprof -svg "$in" > "${base}.svg"        || true
  go tool pprof -png "$in" > "${base}.png"        || true

  # "Clean" callgraph (ignore very small nodes/edges)
  go tool pprof -svg -nodefraction=0.01 -edgefraction=0.01 "$in" > "${base}.clean.svg" || true

  # Textual tables
  go tool pprof -top "$in"       > "${base}_top.txt"      || true
  go tool pprof -top -cum "$in"  > "${base}_top_cum.txt"  || true

  # DOT (optional)
  if command -v dot >/dev/null 2>&1; then
    go tool pprof -dot "$in" > "${base}.dot"              || true
    dot -Tsvg "${base}.dot" -o "${base}.dot.svg"          || true
  fi
}

shopt -s nullglob

# First, .prof profiles (offline bench)
for prof in "$CD"/*.prof; do
  export_one "$prof"
done

# Also export .pb (in case you drop Fabric profiles there)
for pb in "$CD"/*.pb; do
  export_one "$pb"
done

shopt -u nullglob

echo
echo "Done. Artifacts written next to each profile in: $CD"
