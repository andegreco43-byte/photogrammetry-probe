#!/bin/bash
# drive_batch2.sh — reconstruct every image-containing folder anywhere under a
# Google Drive path, regardless of how deeply it is nested.
#
#   ./drive_batch2.sh "<drive path>" [detail]
#
# A "capture" is any folder that directly contains .HEIC images. The script
# finds them at any depth, so it does not matter whether the layout is
#   date/session/            (images直接)
# or
#   date/session/Run N/      (one level deeper)
# or a mix of both under the same date.
#
# Folders whose name starts with "Mouse" are skipped (any level).
# Each .usdz is written back INTO its own source folder on Drive, named after
# a path-derived slug so outputs never collide.
#
# Resumable: a capture whose .usdz already exists on Drive is skipped.

set -u
export PATH="$HOME/bin:$PATH"

DRIVE_PATH="${1:?usage: ./drive_batch2.sh \"<drive path>\" [detail]}"
DETAIL="${2:-full}"
REMOTE="gdrive"
SRC="$REMOTE:$DRIVE_PATH"

WORK="$HOME/scratch/work"
BIN="$(cd "$(dirname "$0")" && pwd)/photogrammetry"
MANIFEST="$HOME/scratch/manifest.csv"
MAXDEPTH=6

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH."; exit 1; }
[ -x "$BIN" ] || { echo "ERROR: photogrammetry not built (run ./setup.sh)."; exit 1; }

echo "Source: $SRC"
rclone lsd "$SRC" >/dev/null 2>&1 || { echo "ERROR: cannot read that path."; exit 1; }

mkdir -p "$WORK" "$HOME/scratch"
[ -f "$MANIFEST" ] || \
  echo "capture,status,detail,elapsed_sec,invalid,skipped,downsampled,finished_utc" > "$MANIFEST"

# --- discover capture folders ------------------------------------------------
# List every .HEIC in the tree, strip to its parent folder, dedupe. Those are
# the folders that actually hold images = the captures.
echo "Scanning for image folders (this can take a moment)..."
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --include "*.HEIC" --include "*.heic" \
  > /tmp/_heics.txt 2>/dev/null

# Parent folder of each image, relative to SRC. Blank = image sits at the top
# level of SRC itself.
sed 's#/[^/]*$##' /tmp/_heics.txt | sort -u > /tmp/_caps_all.txt

# Drop any capture whose path contains a component starting with "Mouse".
grep -vE '(^|/)Mouse' /tmp/_caps_all.txt > /tmp/_caps.txt || true

N=$(grep -c . /tmp/_caps.txt || echo 0)
echo "Found $N capture folder(s) (after excluding Mouse*)."
if [ "$N" -eq 0 ]; then
  echo "Nothing to do. Check the path, or whether images are named .HEIC."
  exit 0
fi
echo

# --- process each ------------------------------------------------------------
while IFS= read -r rel; do
  [ -n "$rel" ] || continue

  # A stable, collision-proof name from the relative path.
  slug=$(echo "$rel" | tr '/' '_' | tr -s ' ' ' ' | tr ' ' '_')
  capsrc="$SRC/$rel"
  [ "$rel" = "." ] && { capsrc="$SRC"; slug=$(basename "$DRIVE_PATH" | tr ' ' '_'); }

  echo "=============================================================="
  echo "  $rel"
  echo "=============================================================="

  if rclone lsf "$capsrc/$slug.usdz" >/dev/null 2>&1; then
    echo "[skip] $slug.usdz already on Drive"
    continue
  fi

  echo "[pull] downloading images..."
  rm -rf "${WORK:?}/$slug"
  mkdir -p "$WORK/$slug"
  if ! rclone copy "$capsrc" "$WORK/$slug" \
        --include "*.HEIC" --include "*.heic" \
        --include "*.TIF"  --include "*.tif" \
        --include "*.TXT"  --include "*.txt" \
        --transfers 8 --retries 5; then
    echo "[FAIL] download failed"
    continue
  fi

  n=$(find "$WORK/$slug" -maxdepth 1 -type f \( -iname '*.heic' \) | wc -l | tr -d ' ')
  echo "[imgs] $n HEIC images"
  [ "$n" -lt 20 ] && echo "[WARN] fewer than 20 images — below protocol minimum"
  if [ "$n" -eq 0 ]; then
    echo "[FAIL] no images after download"
    rm -rf "${WORK:?}/$slug"
    continue
  fi

  out="$WORK/$slug.usdz"
  log="$WORK/$slug.log"
  echo "[run ] reconstructing at --detail $DETAIL ..."
  if "$BIN" "$WORK/$slug" "$out" --detail "$DETAIL" > "$log" 2>&1; then
    status="ok"
  else
    status="FAILED"; echo "[FAIL] see log:"; tail -3 "$log"
  fi

  if [ -f "$out" ]; then
    echo "[push] uploading $(du -h "$out" | cut -f1) back to Drive..."
    rclone copy "$out" "$capsrc/" --retries 5
    rclone copy "$log" "$capsrc/" --retries 5
  fi

  elapsed=$(grep '^elapsed_sec'   "$log" | awk '{print $3}')
  invalid=$(grep '^invalid_total' "$log" | awk '{print $3}')
  skipped=$(grep '^skipped_total' "$log" | awk '{print $3}')
  downsam=$(grep '^downsampled'   "$log" | awk '{print $3}')
  stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$slug,$status,$DETAIL,${elapsed:-},${invalid:-},${skipped:-},${downsam:-},$stamp" >> "$MANIFEST"

  echo "[done] $slug — $status, ${elapsed:-?}s, downsampled=${downsam:-?}"
  rm -rf "${WORK:?}/$slug" "$out" "$log"
  echo
done < /tmp/_caps.txt

echo "=============================================================="
column -s, -t "$MANIFEST"
echo
echo "Problems (non-ok, or downsampled):"
grep -v ",ok," "$MANIFEST" | grep -v '^capture,' || echo "  none"
grep ",true," "$MANIFEST" || true
