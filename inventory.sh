#!/bin/bash
# inventory.sh — scan a Drive tree ONCE and write a reviewable list of every
# real capture (any folder that directly contains .HEIC images, at any depth).
#
#   ./inventory.sh "<drive path>"
#
# Writes ~/scratch/captures.csv with columns:
#   heic_count, depth, dup_group, already_done, path
#
# - dup_group: captures whose timestamps collapse to the same value (ignoring
#   underscores/colons/spaces) share a group id. Review these — they are likely
#   the same capture stored under two spellings.
# - already_done: yes if a .usdz is already sitting in that folder on Drive.
#
# Nothing is reconstructed. Review the CSV, then feed it to run_inventory.sh.

set -u
export PATH="$HOME/bin:$PATH"

DRIVE_PATH="${1:?usage: ./inventory.sh \"<drive path>\"}"
REMOTE="gdrive"
SRC="$REMOTE:$DRIVE_PATH"
OUT="$HOME/scratch/captures.csv"
MAXDEPTH=8

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH (run ./setup.sh)."; exit 1; }
mkdir -p "$HOME/scratch"

echo "Scanning: $SRC"
echo "(one pass over the whole tree — this can take a minute)"

# Every HEIC in the tree.
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --include "*.HEIC" --include "*.heic" \
  > /tmp/_all_heics.txt 2>/dev/null

if [ ! -s /tmp/_all_heics.txt ]; then
  echo "No HEIC files found. Check the path."
  exit 1
fi

# Parent folder of each image = a capture. Count images per folder.
sed 's#/[^/]*$##' /tmp/_all_heics.txt | sort | uniq -c \
  | sed 's/^ *//' > /tmp/_caps_counted.txt   # "<count> <path>"

# Which folders already have a usdz?
rclone lsf "$SRC" -R --max-depth "$MAXDEPTH" --include "*.usdz" 2>/dev/null \
  | sed 's#/[^/]*$##' | sort -u > /tmp/_done.txt

echo "heic_count,depth,dup_group,already_done,path" > "$OUT"

while IFS= read -r line; do
  count=$(echo "$line" | awk '{print $1}')
  path=$(echo "$line" | cut -d' ' -f2-)

  # Skip Mouse* folders anywhere in the path.
  echo "$path" | grep -qE '(^|/)Mouse' && continue

  depth=$(echo "$path" | awk -F/ '{print NF}')

  # Normalized timestamp key: last path component, strip _ : and spaces, lowercase.
  leaf=$(echo "$path" | awk -F/ '{print $NF}')
  key=$(echo "$leaf" | tr -d '_: ' | tr '[:upper:]' '[:lower:]')

  done_flag="no"
  grep -qxF "$path" /tmp/_done.txt && done_flag="yes"

  echo "$count|$depth|$key|$done_flag|$path"
done < /tmp/_caps_counted.txt > /tmp/_rows.txt

# Assign duplicate-group ids: any normalized key appearing more than once.
awk -F'|' '{c[$3]++} END{for(k in c) if(c[k]>1) print k}' /tmp/_rows.txt > /tmp/_dupkeys.txt

gid=0
: > /tmp/_gidmap.txt
while IFS= read -r k; do
  gid=$((gid+1))
  echo "$k dup$gid" >> /tmp/_gidmap.txt
done < /tmp/_dupkeys.txt

while IFS='|' read -r count depth key done_flag path; do
  grp="-"
  g=$(grep -F "$key " /tmp/_gidmap.txt | awk '{print $2}' | head -1)
  [ -n "$g" ] && grp="$g"
  # CSV-quote the path (it has commas and spaces).
  echo "$count,$depth,$grp,$done_flag,\"$path\""
done < /tmp/_rows.txt | sort -t, -k3 >> "$OUT"

TOTAL=$(($(wc -l < "$OUT") - 1))
DUPS=$(grep -c ',dup' "$OUT" || true)
DONE=$(awk -F, '$4=="yes"' "$OUT" | wc -l | tr -d ' ')

echo
echo "=============================================================="
echo " Inventory written: $OUT"
echo "   captures found : $TOTAL"
echo "   already done   : $DONE"
echo "   in a dup group : $DUPS   <-- REVIEW THESE"
echo "=============================================================="
echo
echo "Review duplicates:"
echo "   grep dup \"$OUT\""
echo
echo "See low-image folders (possible bad captures):"
echo "   awk -F, 'NR>1 && \$1<20' \"$OUT\""
echo
echo "When the list looks right, reconstruct with:"
echo "   ./run_inventory.sh full"
