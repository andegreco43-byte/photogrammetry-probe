#!/bin/bash
# reset_usdz.sh — delete USDZ files so they get rebuilt from the CURRENT folder
# structure. Two modes:
#
#   ./reset_usdz.sh "<drive path>"            # DRY RUN — lists what would be deleted
#   ./reset_usdz.sh "<drive path>" --delete   # actually deletes (asks to confirm)
#
# By default it targets ONLY USDZs that sit directly in a session folder that
# ALSO contains Run subfolders — i.e. the stale "fused" reconstructions from
# before the early dates were split. Good per-run USDZs (inside Run folders)
# and correct single-run USDZs (later dates, no Run subfolders) are left alone.
#
# Add --all to instead delete every USDZ under the path (full clean slate).

set -u
export PATH="$HOME/bin:$PATH"

DRIVE_PATH="${1:?usage: ./reset_usdz.sh \"<drive path>\" [--delete] [--all]}"
REMOTE="gdrive"
SRC="$REMOTE:$DRIVE_PATH"
MAXDEPTH=8

DO_DELETE=0; MODE_ALL=0
for a in "$@"; do
  [ "$a" = "--delete" ] && DO_DELETE=1
  [ "$a" = "--all" ] && MODE_ALL=1
done

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH."; exit 1; }

echo "Scanning $SRC ..."
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --retries 8 --low-level-retries 20 \
  --include "*.usdz" > /tmp/_all_usdz.txt 2>/dev/null

if [ "$MODE_ALL" = "1" ]; then
  cp /tmp/_all_usdz.txt /tmp/_target_usdz.txt
  echo "MODE: --all  (every USDZ under the path)"
else
  # Folders that contain Run subfolders (have at least one HEIC under */Run *).
  rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --retries 8 \
    --include "*.HEIC" 2>/dev/null \
    | grep -iE '/Run ?[0-9]+/' \
    | sed -E 's#(/Run ?[0-9]+/).*##' | sort -u > /tmp/_split_parents.txt

  # Target = USDZs whose folder is a split-parent but is NOT itself a Run folder.
  : > /tmp/_target_usdz.txt
  while IFS= read -r u; do
    dir=$(echo "$u" | sed 's#/[^/]*$##')
    echo "$dir" | grep -qiE '/Run ?[0-9]+$' && continue      # skip good per-run usdz
    if grep -qxF "$dir" /tmp/_split_parents.txt; then
      echo "$u" >> /tmp/_target_usdz.txt
    fi
  done < /tmp/_all_usdz.txt
  echo "MODE: fused-parent only  (stale USDZs in folders that now have Run subfolders)"
fi

N=$(grep -c . /tmp/_target_usdz.txt || echo 0)
echo
echo "=============================================================="
echo " Would delete $N USDZ file(s):"
echo "=============================================================="
cat /tmp/_target_usdz.txt
echo "=============================================================="

if [ "$N" -eq 0 ]; then echo "Nothing to delete."; exit 0; fi

if [ "$DO_DELETE" != "1" ]; then
  echo
  echo "DRY RUN. Nothing deleted. Review the list above."
  echo "To actually delete these, re-run with --delete added."
  exit 0
fi

echo
printf "Type DELETE to remove these %s file(s): " "$N"
read -r ans
[ "$ans" = "DELETE" ] || { echo "Aborted."; exit 1; }

while IFS= read -r u; do
  echo "deleting: $u"
  rclone deletefile "$SRC/$u" --retries 5
done < /tmp/_target_usdz.txt

echo "Done. Re-run verify.sh, then run_inventory.sh to rebuild."
