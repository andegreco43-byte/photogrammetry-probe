#!/bin/bash
# flat_reconstruct.sh — reconstruct FLAT capture folders (images directly inside,
# no Run subfolders). Reads the NO_USDZ_FLAT rows from the audit and, for each,
# downloads its images and reconstructs one USDZ written back into that folder.
#
#   ./flat_reconstruct.sh
#
# Resumable: skips any folder that already has its .usdz on Drive.

set -u
export PATH="$HOME/bin:$PATH"

ROOT="R01 Lymphedema Project/Mouse Tail Volumes/MouseTailCaptures"
REMOTE="gdrive"
CSV="$HOME/scratch/audit.csv"
WORK="$HOME/scratch/flatwork"
BIN="$(cd "$(dirname "$0")" && pwd)/photogrammetry"

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH"; exit 1; }
[ -x "$BIN" ] || { echo "ERROR: photogrammetry not built (run ./setup.sh)"; exit 1; }
[ -f "$CSV" ] || { echo "ERROR: no audit.csv — run ./audit.sh first"; exit 1; }

mkdir -p "$WORK"

grep '^NO_USDZ_FLAT' "$CSV" | sed 's/.*,"\([^"]*\)"$/\1/' | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$REMOTE:$ROOT/$rel"
  slug=$(echo "$rel" | tr '/' '_' | tr ' ' '_' | tr ',' '_')
  usdzname="$(basename "$rel").usdz"

  echo "=============================================================="
  echo "  $rel"

  # already done?
  if rclone lsf "$src/$usdzname" --retries 8 >/dev/null 2>&1; then
    echo "  [skip] usdz already present"
    continue
  fi

  echo "  [pull] images..."
  rm -rf "${WORK:?}/$slug"; mkdir -p "$WORK/$slug"
  if ! rclone copy "$src" "$WORK/$slug" \
        --include "*.HEIC" --include "*.heic" \
        --include "*.TIF" --include "*.TXT" \
        --transfers 8 --retries 8 --low-level-retries 20 2>/dev/null; then
    echo "  [FAIL] download"
    continue
  fi

  n=$(find "$WORK/$slug" -maxdepth 1 -iname '*.heic' | wc -l | tr -d ' ')
  echo "  [imgs] $n"
  if [ "$n" -eq 0 ]; then echo "  [FAIL] no images"; rm -rf "${WORK:?}/$slug"; continue; fi

  out="$WORK/$slug.usdz"; log="$WORK/$slug.log"
  echo "  [run ] reconstructing..."
  if "$BIN" "$WORK/$slug" "$out" --detail full > "$log" 2>&1; then
    ds=$(grep '^downsampled' "$log" | awk '{print $3}')
    echo "  [ok  ] downsampled=$ds  -> uploading"
    rclone copy "$out" "$src/" --retries 8
    rclone copy "$log" "$src/" --retries 8
  else
    echo "  [FAIL] reconstruction:"; tail -2 "$log"
  fi
  rm -rf "${WORK:?}/$slug" "$out" "$log"
done

echo
echo "Done. Re-run ./audit.sh to confirm NO_USDZ_FLAT dropped."
