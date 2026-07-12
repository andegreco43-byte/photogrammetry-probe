#!/bin/bash
# setup.sh — one-command session bootstrap for the Stanford Apporto macOS desktop.
#
# The Apporto session is EPHEMERAL: after a timeout or logout the home directory
# may be wiped. Run this at the start of every session. It is idempotent — safe
# to run whether the machine is fresh or already set up.
#
# First session on a clean machine (nothing exists yet):
#
#   cd ~ && git clone https://github.com/andegreco43-byte/photogrammetry-probe.git \
#     && cd photogrammetry-probe && chmod +x setup.sh && ./setup.sh
#
# Every session after that:
#
#   cd ~/photogrammetry-probe && ./setup.sh
#
# (If ~/photogrammetry-probe is gone, the session was wiped — use the first form.)

set -u
cd "$(dirname "$0")"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
ok()   { echo "${GRN}  OK${NC}   $1"; }
warn() { echo "${YEL} WARN${NC}   $1"; }
bad()  { echo "${RED} FAIL${NC}   $1"; }

echo "=================================================="
echo " Rat volumetry — session bootstrap"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)   $USER@$(hostname)"
echo "=================================================="
echo

# --- 1. hardware -------------------------------------------------------------
echo "[1/5] Hardware"
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  bad "architecture is $ARCH, not arm64. Apple photogrammetry will NOT run here."
  exit 1
fi
ok "arch: arm64"

CHIP=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
RAM=$(( $(sysctl -n hw.memsize) / 1073741824 ))
ok "chip: ${CHIP:-unknown}"
ok "ram : ${RAM} GB"
if [ "$RAM" -lt 16 ]; then
  warn "under 16 GB — expect automatic downsampling at --detail full"
fi
case "${CHIP:-}" in
  *Paravirtual*) bad "PARAVIRTUAL GPU — this is a virtualized Mac. Photogrammetry cannot run."; exit 1 ;;
esac

# --- 2. update the code ------------------------------------------------------
echo
echo "[2/5] Repository"
git fetch --quiet origin 2>/dev/null
if ! git diff --quiet 2>/dev/null; then
  # chmod +x shows up as a local change and blocks git pull. Discard it.
  git checkout -- . 2>/dev/null
fi
if git pull --quiet 2>/dev/null; then
  ok "up to date ($(git rev-parse --short HEAD))"
else
  warn "could not pull — continuing with local copy ($(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
fi
chmod +x ./*.sh 2>/dev/null

# --- 3. build ----------------------------------------------------------------
echo
echo "[3/5] Build"
if ! command -v swiftc >/dev/null; then
  bad "swiftc not found. Run: xcode-select --install"
  exit 1
fi
ok "swift: $(swiftc --version 2>/dev/null | head -1 | sed 's/.*Swift version \([0-9.]*\).*/\1/')"

if swiftc -O -parse-as-library -o photogrammetry photogrammetry.swift 2>/tmp/_build.err; then
  ok "built ./photogrammetry"
else
  bad "build failed:"
  cat /tmp/_build.err
  exit 1
fi

# --- 4. the probe: can this machine actually reconstruct? --------------------
echo
echo "[4/5] PhotogrammetrySession"
if swiftc -O -o /tmp/probe probe.swift 2>/dev/null; then
  PROBE=$(/tmp/probe 2>/dev/null)
  if echo "$PROBE" | grep -q "isSupported: true"; then
    ok "isSupported: true"
  else
    bad "isSupported is FALSE on this host. Do NOT reconstruct here."
    bad "Log out and back in to land on a different Apporto host, then re-run."
    exit 1
  fi
else
  bad "could not build probe"
  exit 1
fi

# --- 5. rclone ---------------------------------------------------------------
echo
echo "[5/5] Google Drive (rclone)"
export PATH="$HOME/bin:$PATH"
if ! command -v rclone >/dev/null; then
  warn "rclone not installed — installing now"
  mkdir -p "$HOME/bin"
  ( cd /tmp \
    && curl -sO https://downloads.rclone.org/rclone-current-osx-arm64.zip \
    && unzip -oq rclone-current-osx-arm64.zip \
    && cp rclone-*-osx-arm64/rclone "$HOME/bin/" \
    && chmod +x "$HOME/bin/rclone" \
    && xattr -d com.apple.quarantine "$HOME/bin/rclone" 2>/dev/null )
  grep -q 'HOME/bin' "$HOME/.zshrc" 2>/dev/null || \
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
  ok "rclone installed"
else
  ok "rclone: $(rclone version | head -1)"
fi

if rclone lsd gdrive: >/dev/null 2>&1; then
  ok "gdrive remote authorized"
else
  warn "gdrive remote not configured or not authorized."
  echo
  echo "       Run:  rclone config"
  echo "       Then: n  →  name it exactly 'gdrive'  →  storage type 'drive'"
  echo "             →  Enter (blank client_id)  →  Enter (blank client_secret)"
  echo "             →  scope: 1  →  Enter  →  advanced: n  →  auto config: y"
  echo "             →  sign in via Safari, click Allow"
  echo "             →  shared drive: n  →  keep: y  →  q"
  echo
  echo "       Do NOT pick 's' at the first menu — that is 'set password', not 'new remote'."
fi

# --- provenance --------------------------------------------------------------
mkdir -p "$HOME/scratch"
{
  echo "date   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "user   : $USER@$(hostname)"
  echo "commit : $(git rev-parse HEAD 2>/dev/null)"
  echo "chip   : ${CHIP:-unknown}"
  echo "ram    : ${RAM} GB"
  sw_vers
  swiftc --version | head -1
  /tmp/probe
} > "$HOME/scratch/SESSION_PROVENANCE.txt"

echo
echo "=================================================="
echo " Ready. Provenance: ~/scratch/SESSION_PROVENANCE.txt"
echo
echo " Reconstruct a Drive folder:"
echo "   ./drive_batch.sh \"R01 Lymphedema Project/Mouse Tail Volumes/Captures/Captures\" full"
echo "=================================================="
