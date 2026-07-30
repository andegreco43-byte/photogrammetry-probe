#!/bin/bash
# audit.sh — sweep the capture tree and report, per session folder:
#   - CORRUPT : folder exists in parent listing but its contents can't be read
#   - NO_USDZ : readable, has images, but no reconstruction yet
#   - NO_RUNS : has images directly (not nested in Run subfolders)
#   - OK      : has images and a usdz
#
#   ./audit.sh
#
# Writes ~/scratch/audit.csv. Read-only — changes nothing on Drive.

set -u
export PATH="$HOME/bin:$PATH"

REMOTE="gdrive"
ROOT="R01 Lymphedema Project/Mouse Tail Volumes/MouseTailCaptures"
SRC="$REMOTE:$ROOT"
OUT="$HOME/scratch/audit.csv"
mkdir -p "$HOME/scratch"

command -v rclone >/dev/null || { echo "ERROR: rclone not on PATH (run ./setup.sh, then export PATH=\$HOME/bin:\$PATH)"; exit 1; }

echo "status,date,session,detail,path" > "$OUT"

echo "Listing date folders..."
# Date folders = top-level, excluding the separate Mouse cohort.
rclone lsf "$SRC" --dirs-only --retries 10 2>/dev/null | sed 's#/$##' \
  | grep -vE '^Mouse' > /tmp/_dates.txt

echo "Found $(grep -c . /tmp/_dates.txt) date folders."
echo

while IFS= read -r DATE; do
  [ -n "$DATE" ] || continue
  echo "### $DATE"

  # Session folders under this date.
  if ! rclone lsf "$SRC/$DATE" --dirs-only --retries 10 2>/dev/null | sed 's#/$##' > /tmp/_sessions.txt; then
    echo "CORRUPT,\"$DATE\",,,\"$DATE\"" >> "$OUT"
    echo "  [CORRUPT] cannot list sessions under $DATE"
    continue
  fi

  # A date with no sub-sessions but with images directly (later single-run style)
  if [ ! -s /tmp/_sessions.txt ]; then
    hc=$(rclone lsf "$SRC/$DATE" --include "*.HEIC" --retries 10 2>/dev/null | wc -l | tr -d ' ')
    echo "  (no sessions; $hc HEICs directly)"
    continue
  fi

  while IFS= read -r S; do
    [ -n "$S" ] || continue
    P="$DATE/$S"

    # Try to read the session's full contents. Capture stderr to detect corruption.
    listing=$(rclone lsf "$SRC/$P" -R --retries 12 --low-level-retries 20 2>/tmp/_err.txt)
    if grep -q "directory not found\|couldn't find" /tmp/_err.txt && [ -z "$listing" ]; then
      echo "CORRUPT,\"$DATE\",\"$S\",,\"$P\"" >> "$OUT"
      echo "  [CORRUPT] $S"
      continue
    fi

    has_heic=$(echo "$listing" | grep -ic "\.heic$")
    has_usdz=$(echo "$listing" | grep -ic "\.usdz$")
    has_runs=$(echo "$listing" | grep -icE '/Run ?[0-9]+/')

    if [ "$has_heic" -eq 0 ]; then
      echo "CORRUPT,\"$DATE\",\"$S\",,\"$P\"" >> "$OUT"
      echo "  [CORRUPT/EMPTY] $S (no images readable)"
    elif [ "$has_usdz" -gt 0 ]; then
      echo "OK,\"$DATE\",\"$S\",,\"$P\"" >> "$OUT"
    elif [ "$has_runs" -gt 0 ]; then
      echo "NO_USDZ_RUNS,\"$DATE\",\"$S\",,\"$P\"" >> "$OUT"
      echo "  [NO USDZ, has Runs] $S"
    else
      echo "NO_USDZ_FLAT,\"$DATE\",\"$S\",,\"$P\"" >> "$OUT"
      echo "  [NO USDZ, flat images] $S"
    fi
  done < /tmp/_sessions.txt

done < /tmp/_dates.txt

echo
echo "=============================================================="
echo " Audit written: $OUT"
echo "=============================================================="
echo "CORRUPT (recopy from hard drive):"
grep '^CORRUPT' "$OUT" | sed 's/^CORRUPT,/  /'
echo
echo "NO USDZ (need reconstruction):"
grep '^NO_USDZ' "$OUT" | sed 's/^[^,]*,/  /'
echo
echo "Counts:"
for s in OK CORRUPT NO_USDZ_RUNS NO_USDZ_FLAT; do
  echo "  $s : $(grep -c "^$s," "$OUT")"
done
