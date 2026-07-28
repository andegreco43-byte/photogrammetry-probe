#!/bin/bash
# verify.sh — the source of truth for "what still needs reconstructing".
#
#   ./verify.sh "<drive path>"
#
# Ignores the manifest and the inventory entirely. Walks the Drive tree, finds
# every folder that directly contains .HEIC images (a capture), and checks
# whether that same folder already contains a .usdz. Prints the ones that don't.
#
# This is drift-proof: it reflects the actual state of Drive at run time, so it
# catches folders the inventory missed, folders added since, and runs that
# failed to upload.
#
# Writes ~/scratch/missing.csv (same format as captures.csv) — feed it straight
# to run_inventory.sh (after swapping it in as captures.csv) to fill the gaps.

set -u
export PATH="$HOME/bin:$PATH"

DRIVE_PATH="${1:?usage: ./verify.sh \"<drive path>\"}"
REMOTE="gdrive"
SRC="$REMOTE:$DRIVE_PATH"
MAXDEPTH=8
MISSING="$HOME/scratch/missing.csv"

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH (run ./setup.sh)."; exit 1; }
mkdir -p "$HOME/scratch"

echo "Scanning $SRC (retrying transient errors)..."

# --retries smooths over the flaky shared client_id that causes phantom
# "directory not found" errors mid-scan.
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --retries 8 --low-level-retries 20 \
  --include "*.HEIC" --include "*.heic" > /tmp/_v_heics.txt 2>/dev/null
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --retries 8 --low-level-retries 20 \
  --include "*.usdz" > /tmp/_v_usdz.txt 2>/dev/null

# Capture folders = parents of HEICs, excluding Mouse*, with a sane image count.
sed 's#/[^/]*$##' /tmp/_v_heics.txt | grep -vE '(^|/)Mouse' | sort | uniq -c \
  | sed 's/^ *//' > /tmp/_v_caps.txt      # "<count> <path>"

# Folders that already hold a usdz.
sed 's#/[^/]*$##' /tmp/_v_usdz.txt | sort -u > /tmp/_v_done.txt

echo "heic_count,depth,dup_group,already_done,path" > "$MISSING"

total=0; done=0; missing=0; toosmall=0; toobig=0
while IFS= read -r line; do
  count=$(echo "$line" | awk '{print $1}')
  path=$(echo "$line" | cut -d' ' -f2-)
  total=$((total+1))

  # Flag, but don't queue, folders outside a plausible single-run range.
  if [ "$count" -lt 25 ]; then toosmall=$((toosmall+1)); continue; fi
  if [ "$count" -gt 60 ]; then toobig=$((toobig+1)); continue; fi

  if grep -qxF "$path" /tmp/_v_done.txt; then
    done=$((done+1))
  else
    missing=$((missing+1))
    depth=$(echo "$path" | awk -F/ '{print NF}')
    echo "$count,$depth,-,no,\"$path\"" >> "$MISSING"
  fi
done < /tmp/_v_caps.txt

echo
echo "=============================================================="
echo " Reality check against Drive:"
echo "   capture folders (25-60 imgs) : $((total - toosmall - toobig))"
echo "     already have a .usdz       : $done"
echo "     STILL MISSING              : $missing   -> $MISSING"
echo "   excluded (<25 imgs)          : $toosmall   (date folders / fragments)"
echo "   excluded (>60 imgs)          : $toobig   (multi-run folders — handle separately)"
echo "=============================================================="
echo
if [ "$missing" -gt 0 ]; then
  echo "To reconstruct the missing ones:"
  echo "   cp ~/scratch/captures.csv ~/scratch/captures_prev.csv   # keep current queue"
  echo "   cp $MISSING ~/scratch/captures.csv"
  echo "   ./run_inventory.sh full"
fi
echo "Multi-run folders (>60 imgs) are listed here for review:"
awk '{c=$1; $1=""; if(c>60) print c" "$0}' /tmp/_v_caps.txt | grep -vE 'Mouse' | head -40
