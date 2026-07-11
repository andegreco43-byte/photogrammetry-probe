#!/bin/bash
# batch.sh — reconstruct every CaptureSample folder under an input root.
#
#   ./batch.sh <input-root> <output-root> [detail]
#
# Expects input-root to contain one subfolder per capture, e.g.
#
#   captures/
#     rat03_wk04_run1/
#     rat03_wk04_run2/
#     ...
#
# Produces output-root/<capture-name>.usdz plus a per-capture log, and
# appends one row per capture to output-root/manifest.csv.
#
# Safe to re-run: captures whose .usdz already exists are skipped, so if the
# session dies partway you just run it again.

set -u

INPUT_ROOT="${1:?usage: batch.sh <input-root> <output-root> [detail]}"
OUTPUT_ROOT="${2:?usage: batch.sh <input-root> <output-root> [detail]}"
DETAIL="${3:-full}"

BIN="$(cd "$(dirname "$0")" && pwd)/photogrammetry"
if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN not found. Build it first:"
  echo "  swiftc -O -parse-as-library -o photogrammetry photogrammetry.swift"
  exit 1
fi

mkdir -p "$OUTPUT_ROOT/logs"
MANIFEST="$OUTPUT_ROOT/manifest.csv"
if [ ! -f "$MANIFEST" ]; then
  echo "capture,status,detail,elapsed_sec,invalid,skipped,downsampled,finished_utc" > "$MANIFEST"
fi

for dir in "$INPUT_ROOT"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  out="$OUTPUT_ROOT/$name.usdz"
  log="$OUTPUT_ROOT/logs/$name.log"

  if [ -f "$out" ]; then
    echo "[skip] $name (already reconstructed)"
    continue
  fi

  echo "[run ] $name"
  if "$BIN" "$dir" "$out" --detail "$DETAIL" > "$log" 2>&1; then
    status="ok"
  else
    status="FAILED"
    echo "[FAIL] $name — see $log"
  fi

  elapsed=$(grep '^elapsed_sec' "$log" | awk '{print $3}')
  invalid=$(grep '^invalid_total' "$log" | awk '{print $3}')
  skipped=$(grep '^skipped_total' "$log" | awk '{print $3}')
  downsam=$(grep '^downsampled' "$log" | awk '{print $3}')
  stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "$name,$status,$DETAIL,${elapsed:-},${invalid:-},${skipped:-},${downsam:-},$stamp" >> "$MANIFEST"
done

echo
echo "Done. Manifest: $MANIFEST"
