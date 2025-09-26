#!/bin/bash
set -euo pipefail

# Directory containing your captured profiles (adjust as needed)
CD="./profiles/20250925_194743"

# Ensure directory exists
[ -d "$CD" ] || { echo "Folder not found: $CD"; exit 1; }

echo "Exporting pprof artifacts from: $CD"

# Function to export for a single .pb profile
export_one() {
  local in="$1"
  local base="${in%.*}"                # strip .pb
  local name="$(basename "$base")"     # file name without ext

  echo "-> $name"

  # Standard callgraph exports (SVG/PNG)
  go tool pprof -svg "$in" > "${base}.svg" || true
  go tool pprof -png "$in" > "${base}.png" || true

  # Cleaned callgraph (hides tiny nodes/edges so big blocks stand out)
  go tool pprof -svg -nodefraction=0.01 -edgefraction=0.01 "$in" > "${base}.clean.svg" || true

  # Tables
  go tool pprof -top "$in" > "${base}_top.txt" || true
  # Cumulative table (not all profiles support it; try anyway)
  go tool pprof -top -cum "$in" > "${base}_top_cum.txt" || true

  # Optional: DOT (for Graphviz workflows)
  if command -v dot >/dev/null 2>&1; then
    go tool pprof -dot "$in" > "${base}.dot" || true
    dot -Tsvg "${base}.dot" -o "${base}.dot.svg" || true
  fi
}

# Export for each .pb profile found
shopt -s nullglob
for pb in "$CD"/*.pb; do
  export_one "$pb"
done
shopt -u nullglob

echo
echo "Done. Files written next to each .pb in: $CD"
echo
echo "Notes:"
echo "1) CPU profile SVG/PNG are callgraphs. The interactive Flame Graph lives in the web UI."
echo "   If you need a static flame graph image, open:"
echo "      go tool pprof -http=:8081 \"$CD/cpu_profile.pb\""
echo "   then use the browser's 'Flame Graph' view and take a screenshot."
echo "2) The execution trace (trace.out) has no direct SVG export."
echo "   Use:"
echo "      go tool trace \"$CD/trace.out\""
echo "   then screenshot the timeline with overlapping goroutines as proof of parallelism."
