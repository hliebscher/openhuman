#!/bin/bash
# Full build workflow: sync upstream → build → cleanup
# Usage: bash scripts/build-and-sync.sh [--force] [--no-cleanup]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FORCE=0
NO_CLEANUP=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --no-cleanup) NO_CLEANUP=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "════════════════════════════════════════════════════════════"
echo "🔄 OpenHuman Build Workflow"
echo "════════════════════════════════════════════════════════════"
echo ""

# Step 1: Sync with upstream
echo "📡 STEP 1: Syncing with upstream/main..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
git fetch upstream
if git merge upstream/main --no-edit > /dev/null 2>&1; then
  echo "✓ Merged upstream/main"
else
  echo "⚠ Already up to date or merge conflict"
fi
echo ""

# Step 2: Build
echo "🔨 STEP 2: Building OpenHuman..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $FORCE -eq 1 ]; then
  pnpm daily:build --force
else
  pnpm daily:build
fi
BUILD_EXIT=$?

if [ $BUILD_EXIT -ne 0 ]; then
  echo "❌ Build failed!"
  exit 1
fi
echo ""

# Step 3: Cleanup (optional)
if [ $NO_CLEANUP -eq 0 ]; then
  echo "🧹 STEP 3: Cleaning up build artifacts..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bash "$SCRIPT_DIR/cleanup-builds.sh" 2>&1 | sed 's/^/  /'
  echo ""
fi

# Show result
echo "════════════════════════════════════════════════════════════"
echo "✅ Build Complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
cat target/daily-build/last-build.json | jq '{
  version: .version,
  status: .status,
  app: .app_path,
  finished_at: .finished_at
}'
echo ""
echo "🚀 To launch:"
echo "   open \"/Users/liebscher/Applications/OpenHuman (Daily).app\""
echo ""
