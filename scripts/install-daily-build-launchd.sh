#!/usr/bin/env bash
# Install (or refresh) the daily OpenHuman build launchd agent.
#
# Usage:
#   scripts/install-daily-build-launchd.sh            # install + load
#   scripts/install-daily-build-launchd.sh --unload   # unload + remove plist
#   scripts/install-daily-build-launchd.sh --hour 7 --minute 30

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/launchd/com.openhuman.daily-build.plist.template"
LABEL="com.openhuman.daily-build"
DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

UNLOAD=0
HOUR=6
MINUTE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unload) UNLOAD=1; shift ;;
    --hour) HOUR="${2:-}"; shift 2 ;;
    --minute) MINUTE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install-daily-build-launchd: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

chmod +x "$REPO_ROOT/scripts/daily-local-build.sh"

if [[ "$UNLOAD" -eq 1 ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$DEST" 2>/dev/null || true
  rm -f "$DEST"
  echo "[install-daily-build-launchd] removed $DEST"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$REPO_ROOT/target/daily-build/logs"

RUST_CHANNEL="$(grep -E '^channel\s*=' "$REPO_ROOT/rust-toolchain.toml" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || echo "1.93.0")"
RUST_BIN="$HOME/.rustup/toolchains/${RUST_CHANNEL}-aarch64-apple-darwin/bin"

sed \
  -e "s|@@REPO_ROOT@@|$REPO_ROOT|g" \
  -e "s|@@HOME_DIR@@|$HOME|g" \
  -e "s|@@RUST_BIN@@|$RUST_BIN|g" \
  "$TEMPLATE" >"$DEST.tmp"

# Patch schedule hour/minute without requiring a second template.
/usr/bin/plutil -replace StartCalendarInterval.Hour -integer "$HOUR" "$DEST.tmp"
/usr/bin/plutil -replace StartCalendarInterval.Minute -integer "$MINUTE" "$DEST.tmp"
mv "$DEST.tmp" "$DEST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST" 2>/dev/null || launchctl load "$DEST"

echo "[install-daily-build-launchd] installed $DEST"
echo "[install-daily-build-launchd] schedule: daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
echo "[install-daily-build-launchd] fork remote: origin (override: OPENHUMAN_SYNC_REMOTE)"
echo "[install-daily-build-launchd] track branch: daily-local-build (override: OPENHUMAN_TRACK_BRANCH)"
echo "[install-daily-build-launchd] macOS target: aarch64-apple-darwin (Apple Silicon only)"
echo "[install-daily-build-launchd] manual run: $REPO_ROOT/scripts/daily-local-build.sh"
echo "[install-daily-build-launchd] logs: $REPO_ROOT/target/daily-build/logs/"
