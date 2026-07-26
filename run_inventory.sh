#!/bin/bash
# run_inventory.sh — reconstruct every capture listed in ~/scratch/captures.csv
# (produced and reviewed via inventory.sh).
#
#   ./run_inventory.sh [detail]
#
# Skips rows already marked done, and re-skips anything whose .usdz appears on
# Drive at run time, so it is fully resumable across session timeouts.
#
# To EXCLUDE a duplicate you don't want, delete its line from captures.csv
# before running (or blank the path). The runner only processes what's listed.

set -u
export PATH="$HOME/bin:$PATH"

DETAIL="${1:-full}"
REMOTE="gdrive"
BASEDRIVE="R01 Lymphedema Project/Mouse Tail Volumes/MouseTailCaptures"
CSV="$HOME/scratch/captures.csv"
WORK="$HOME/scratch/work"
BIN="$(cd "$(dirname "$0")" && pwd)/photogrammetry"
MANIFEST="$HOME/scratch/manifest.csv"

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH."; exit 1; }
[ -x "$BIN" ] || { echo "ERROR: photogrammetry not built (run ./setup.sh)."; exit 1; }
[ -f "$CSV" ] || { echo "ERROR: no $CSV — run ./inventory.sh first."; exit 1; }

mkdir -p "$WORK"
[ -f "$MANIFEST" ] || \
  echo "capture,status,detail,elapsed_sec,invalid,skipped,downsampled,finished_utc" > "$MANIFEST"

# Parse CSV, skipping header. Path is the quoted 5th field.
tail -n +2 "$CSV" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  rel=$(echo "$line" | sed 's/^[^,]*,[^,]*,[^,]*,[^,]*,//' | sed 's/^"//; s/"$//')
  [ -n "$rel" ] || continue

  # rel is relative to the base captures dir (paths in the CSV are relative to SRC,
  # and inventory.sh was pointed at BASEDRIVE). If you scanned a subfolder, adjust.
  capsrc="$REMOTE:$BASEDRIVE/$rel"
  slug=$(echo "$rel" | tr '/' '_' | tr -d ':' | tr ' ' '_')

  echo "=============================================================="
  echo "  $rel"
  echo "=============================================================="

  if rclone lsf "$capsrc/$slug.usdz" >/dev/null 2>&1; then
    echo "[skip] already reconstructed"
    continue
  fi

  echo "[pull] downloading..."
  rm -rf "${WORK:?}/$slug"; mkdir -p "$WORK/$slug"
  if ! rclone copy "$capsrc" "$WORK/$slug" \
        --include "*.HEIC" --include "*.heic" \
        --include "*.TIF"  --include "*.tif" \
        --include "*.TXT"  --include "*.txt" \
        --transfers 8 --retries 5; then
    echo "[FAIL] download"; continue
  fi

  n=$(find "$WORK/$slug" -maxdepth 1 -type f -iname '*.heic' | wc -l | tr -d ' ')
  echo "[imgs] $n HEIC"
  [ "$n" -lt 20 ] && echo "[WARN] fewer than 20 images"
  if [ "$n" -eq 0 ]; then echo "[FAIL] no images"; rm -rf "${WORK:?}/$slug"; continue; fi

  out="$WORK/$slug.usdz"; log="$WORK/$slug.log"
  echo "[run ] --detail $DETAIL ..."
  if "$BIN" "$WORK/$slug" "$out" --detail "$DETAIL" > "$log" 2>&1; then status="ok"
  else status="FAILED"; echo "[FAIL]"; tail -3 "$log"; fi

  if [ -f "$out" ]; then
    echo "[push] $(du -h "$out" | cut -f1) -> Drive"
    rclone copy "$out" "$capsrc/" --retries 5
    rclone copy "$log" "$capsrc/" --retries 5
  fi

  el=$(grep '^elapsed_sec' "$log" | awk '{print $3}')
  iv=$(grep '^invalid_total' "$log" | awk '{print $3}')
  sk=$(grep '^skipped_total' "$log" | awk '{print $3}')
  ds=$(grep '^downsampled' "$log" | awk '{print $3}')
  echo "$slug,$status,$DETAIL,${el:-},${iv:-},${sk:-},${ds:-},$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST"
  echo "[done] $slug — $status, downsampled=${ds:-?}"
  rm -rf "${WORK:?}/$slug" "$out" "$log"
  echo
done

echo "=============================================================="
echo "Problems (non-ok, or downsampled):"
grep -v ",ok," "$MANIFEST" | grep -v '^capture,' || echo "  none"
grep ",true," "$MANIFEST" || true
