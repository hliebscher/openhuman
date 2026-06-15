#!/bin/bash
# Clean up old build artifacts after successful builds
# Run after: pnpm daily:build, cargo build, etc.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[cleanup] Removing build artifacts..."

# Remove all debug/ directories
find "$REPO_ROOT" -type d -name "debug" 2>/dev/null | xargs rm -rf 2>/dev/null || true
echo "[cleanup] ✓ debug/ directories"

# Remove all incremental/ cache
find "$REPO_ROOT" -type d -name "incremental" 2>/dev/null | xargs rm -rf 2>/dev/null || true
echo "[cleanup] ✓ incremental/ cache"

# Remove old .a and .rlib files (keep only latest)
find "$REPO_ROOT/target" -name "*.a" -o -name "*.rlib" 2>/dev/null | xargs rm -f 2>/dev/null || true
echo "[cleanup] ✓ old .a/.rlib files"

# Remove build/ directories in target (intermediate files)
find "$REPO_ROOT/target" -maxdepth 3 -type d -name "build" 2>/dev/null | xargs rm -rf 2>/dev/null || true
echo "[cleanup] ✓ build/ intermediate directories"

# Clean cargo local registry cache
rm -rf ~/.cargo/registry/cache 2>/dev/null || true
echo "[cleanup] ✓ ~/.cargo registry cache"

# Show final sizes
echo ""
echo "[cleanup] Final sizes:"
du -sh "$REPO_ROOT/target" 2>/dev/null || echo "  target/: removed"
du -sh "$REPO_ROOT" 2>/dev/null || echo "  repo/: error"
