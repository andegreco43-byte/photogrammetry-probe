#!/bin/bash
# drive_batch.sh — reconstruct every capture folder in a Google Drive directory
# and write each resulting .usdz back INTO its own source folder.
#
#   ./drive_batch.sh "<drive path>" [detail]
#
# Example:
#   ./drive_batch.sh "R01 Lymphedema Project/Mouse Tail Volumes/Batch2Captures" full
#
# Requires: rclone configured with a remote named "gdrive" (rclone config),
#           and ./photogrammetry already built.
#
# Resumable: a folder that already contains its .usdz on Drive is skipped, so
# if the session drops you just run it again.

set -u

DRIVE_PATH="${1:?usage: ./drive_batch.sh \"<drive path>\" [detail]}"
DETAIL="${2:-full}"

REMOTE="gdrive"

SRC="$REMOTE:$DRIVE_PATH"
WORK="$HOME/scratch/work"
BIN="$(cd "$(dirname "$0")" && pwd)/photogrammetry"
MANIFEST="$HOME/scratch/manifest.csv"

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH. Run the rclone install block."; exit 1; }
[ -x "$BIN" ] || { echo "ERROR: photogrammetry not built. Run swiftc first."; exit 1; }

echo "Checking Drive path..."
if ! rclone lsd "$SRC" >/dev/null 2>&1; then
  echo "ERROR: cannot read '$SRC'"
  echo "Check the path. List what rclone can see with:"
  echo "  rclone lsd $REMOTE:"
  exit 1
fi

mkdir -p "$WORK"
[ -f "$MANIFEST" ] || \
  echo "capture,status,detail,elapsed_sec,invalid,skipped,downsampled,finished_utc" > "$MANIFEST"

# Folder names may contain spaces — read them line by line, never word-split.
rclone lsf "$SRC" --dirs-only | sed 's#/$##' > /tmp/_folders.txt
echo "Found $(wc -l < /tmp/_folders.txt) folders."
echo

while IFS= read -r name; do
  [ -n "$name" ] || continue

  echo "=============================================================="
  echo "  $name"
  echo "=============================================================="

  # Already done? (usdz sitting in the source folder on Drive)
  if rclone lsf "$SRC/$name/$name.usdz" >/dev/null 2>&1; then
    echo "[skip] .usdz already present on Drive"
    continue
  fi

  # 1. pull down (images only — don't re-download any usdz already there)
  echo "[pull] downloading..."
  rm -rf "${WORK:?}/$name"
  if ! rclone copy "$SRC/$name" "$WORK/$name" \
        --exclude "*.usdz" --exclude "*.log" --transfers 8; then
    echo "[FAIL] download failed"
    continue
  fi

  # 2. locate the images — CaptureSample sometimes nests them one level down
  IMGDIR="$WORK/$name"
  n=$(find "$IMGDIR" -maxdepth 1 -type f \
        \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    sub=$(find "$IMGDIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$sub" ]; then
      IMGDIR="$sub"
      n=$(find "$IMGDIR" -maxdepth 1 -type f \
            \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' ')
    fi
  fi

  echo "[imgs] $n images in $(basename "$IMGDIR")"
  if [ "$n" -lt 20 ]; then
    echo "[WARN] fewer than 20 images — protocol minimum not met"
  fi
  if [ "$n" -eq 0 ]; then
    echo "[FAIL] no images found"
    rm -rf "${WORK:?}/$name"
    continue
  fi

  # 3. reconstruct
  out="$WORK/$name.usdz"
  log="$WORK/$name.log"
  echo "[run ] reconstructing at --detail $DETAIL ..."
  if "$BIN" "$IMGDIR" "$out" --detail "$DETAIL" > "$log" 2>&1; then
    status="ok"
  else
    status="FAILED"
    echo "[FAIL] see log"
    tail -3 "$log"
  fi

  # 4. push the usdz + log back into the SAME Drive folder
  if [ -f "$out" ]; then
    echo "[push] uploading $(du -h "$out" | cut -f1) back to Drive..."
    rclone copy "$out" "$SRC/$name/"
    rclone copy "$log" "$SRC/$name/"
  fi

  # 5. record + clean up
  elapsed=$(grep '^elapsed_sec' "$log" | awk '{print $3}')
  invalid=$(grep '^invalid_total' "$log" | awk '{print $3}')
  skipped=$(grep '^skipped_total' "$log" | awk '{print $3}')
  downsam=$(grep '^downsampled'  "$log" | awk '{print $3}')
  stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$name,$status,$DETAIL,${elapsed:-},${invalid:-},${skipped:-},${downsam:-},$stamp" >> "$MANIFEST"

  echo "[done] $name — ${status}, ${elapsed:-?}s, downsampled=${downsam:-?}"
  rm -rf "${WORK:?}/$name" "$out" "$log"
  echo

done < /tmp/_folders.txt

echo "=============================================================="
echo "Batch complete. Manifest:"
column -s, -t "$MANIFEST"
echo
echo "Rows to investigate (anything not 'ok', or any downsampling):"
grep -v ",ok," "$MANIFEST" | grep -v '^capture,' || echo "  none"
grep ",true," "$MANIFEST" || true
