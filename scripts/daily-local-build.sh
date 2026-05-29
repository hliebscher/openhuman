#!/usr/bin/env bash
# Daily local macOS build: sync your GitHub fork, build release .app + DMG when changed.
#
# Defaults track origin/daily-local-build on your fork. Optionally merges
# upstream/main (tinyhumansai/openhuman) before each build and pushes back to origin.
#
# Usage (from repo root or anywhere):
#   scripts/daily-local-build.sh              # update + build only when HEAD moved
#   scripts/daily-local-build.sh --force      # build even when up to date; dirty tree → local-only
#   scripts/daily-local-build.sh --no-sync    # skip git fetch/merge; build current tree
#   scripts/daily-local-build.sh --dry-run    # fetch + report; no checkout/build
#   scripts/daily-local-build.sh --debug      # debug build instead of release
#
# Environment:
#   OPENHUMAN_SYNC_REMOTE=origin              Fork remote (default: origin)
#   OPENHUMAN_TRACK_BRANCH=daily-local-build   Branch on your fork
#   OPENHUMAN_MERGE_UPSTREAM=1                Merge upstream/main before build (default: 1)
#
# Schedule daily with launchd:
#   scripts/install-daily-build-launchd.sh
#
# Logs:  target/daily-build/logs/
# State: target/daily-build/last-build.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SYNC_REMOTE="${OPENHUMAN_SYNC_REMOTE:-origin}"
TRACK_BRANCH="${OPENHUMAN_TRACK_BRANCH:-daily-local-build}"
MERGE_UPSTREAM="${OPENHUMAN_MERGE_UPSTREAM:-1}"
REMOTE_REF="${SYNC_REMOTE}/${TRACK_BRANCH}"

FORCE=0
DRY_RUN=0
NO_SYNC=0
BUILD_MODE="release"
APPLICATIONS_LINK="${HOME}/Applications/OpenHuman (Daily).app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; continue ;;
    --force) FORCE=1; shift ;;
    --no-sync) NO_SYNC=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --debug) BUILD_MODE="debug"; shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "[daily-build] unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

LOG_DIR="$REPO_ROOT/target/daily-build/logs"
STATE_DIR="$REPO_ROOT/target/daily-build"
LOCK_FILE="$STATE_DIR/.lock"
mkdir -p "$LOG_DIR" "$STATE_DIR"

TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
LOG_FILE="$LOG_DIR/daily-build-${TIMESTAMP}.log"
ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[daily-build] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

acquire_lock() {
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    log "another daily build appears to be running (lock: $LOCK_FILE); exiting"
    exit 0
  fi
  trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT
}

write_state() {
  local sha="$1" version="$2" app_path="$3" dmg_path="$4" status="$5"
  cat >"$STATE_DIR/last-build.json" <<EOF
{
  "status": "$status",
  "sha": "$sha",
  "version": "$version",
  "build_mode": "$BUILD_MODE",
  "app_path": "$app_path",
  "dmg_path": "$dmg_path",
  "applications_link": "$APPLICATIONS_LINK",
  "sync_remote": "$SYNC_REMOTE",
  "track_branch": "$TRACK_BRANCH",
  "remote_ref": "$REMOTE_REF",
  "merge_upstream": "$MERGE_UPSTREAM",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

ensure_sync_remote() {
  if git remote get-url "$SYNC_REMOTE" >/dev/null 2>&1; then
    return 0
  fi
  log "remote '$SYNC_REMOTE' is missing; add your fork first, e.g.:"
  log "  git remote add origin https://github.com/<you>/openhuman.git"
  exit 1
}

setup_build_path() {
  local channel
  channel="$(grep -E '^channel\s*=' rust-toolchain.toml 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || echo "1.93.0")"
  export PATH="$HOME/.rustup/toolchains/${channel}-aarch64-apple-darwin/bin:$HOME/.cargo/bin:${REPO_ROOT}/.cache/cargo-install/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  export CEF_PATH="${CEF_PATH:-$HOME/Library/Caches/tauri-cef}"
  export OPENHUMAN_CARGO_INSTALL_ROOT="${OPENHUMAN_CARGO_INSTALL_ROOT:-$REPO_ROOT/.cache/cargo-install}"
  mkdir -p "$CEF_PATH" "$OPENHUMAN_CARGO_INSTALL_ROOT"
}

merge_upstream_main() {
  if [[ "$MERGE_UPSTREAM" != "1" ]]; then
    log "upstream merge disabled (OPENHUMAN_MERGE_UPSTREAM=$MERGE_UPSTREAM)"
    return 0
  fi
  if ! git remote get-url upstream >/dev/null 2>&1; then
    log "no upstream remote; skipping upstream merge"
    return 0
  fi
  if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
    log "upstream/main not found after fetch; skipping upstream merge"
    return 0
  fi

  log "merging upstream/main into $TRACK_BRANCH..."
  if git merge --ff-only upstream/main; then
    log "fast-forwarded with upstream/main"
  elif git merge upstream/main -m "chore(daily-build): merge upstream/main"; then
    log "merge commit created for upstream/main"
  else
    log "ERROR: merge from upstream/main failed; resolve conflicts manually"
    exit 1
  fi
}

push_to_fork() {
  local before_sha after_sha
  before_sha="$(git rev-parse "${SYNC_REMOTE}/${TRACK_BRANCH}" 2>/dev/null || echo "")"
  after_sha="$(git rev-parse HEAD)"

  if [[ "$before_sha" == "$after_sha" ]]; then
    log "fork remote already at HEAD; no push needed"
    return 0
  fi

  log "pushing $TRACK_BRANCH to $SYNC_REMOTE..."
  if git push "$SYNC_REMOTE" "$TRACK_BRANCH"; then
    log "pushed $after_sha to $REMOTE_REF"
  else
    log "WARNING: push to $REMOTE_REF failed (build will continue from local HEAD)"
  fi
}

sync_from_fork() {
  local before_sha after_sha dirty_files

  if [[ "$NO_SYNC" -eq 1 ]]; then
    log "--no-sync: skipping git fetch/merge; building current working tree"
    before_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    log "local HEAD: $before_sha"
    log "installing JS dependencies..."
    pnpm install --frozen-lockfile 2>/dev/null || pnpm install
    return 0
  fi

  log "fetching remotes (fork=$SYNC_REMOTE branch=$TRACK_BRANCH merge_upstream=$MERGE_UPSTREAM)..."
  if [[ "$MERGE_UPSTREAM" == "1" ]] && git remote get-url upstream >/dev/null 2>&1; then
    git fetch upstream --prune
  fi
  git fetch "$SYNC_REMOTE" --prune --tags

  if ! git rev-parse --verify "$REMOTE_REF" >/dev/null 2>&1; then
    log "ERROR: $REMOTE_REF does not exist on the fork yet"
    log "create and push the branch first, e.g.: git push -u $SYNC_REMOTE $TRACK_BRANCH"
    exit 1
  fi

  before_sha="$(git rev-parse "$TRACK_BRANCH" 2>/dev/null || echo "")"
  log "local $TRACK_BRANCH before sync: ${before_sha:-<missing>}"
  log "fork $REMOTE_REF: $(git rev-parse "$REMOTE_REF")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would sync $TRACK_BRANCH from $REMOTE_REF, optionally merge upstream/main, then build ($BUILD_MODE)"
    exit 0
  fi

  dirty_files="$(git status --porcelain --untracked-files=no || true)"
  if [[ -n "$dirty_files" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      log "WARNING: uncommitted tracked changes — skipping sync, building local tree (--force)"
      log "dirty files:"
      echo "$dirty_files" | sed 's/^/[daily-build]   /'
      log "installing JS dependencies..."
      pnpm install --frozen-lockfile 2>/dev/null || pnpm install
      return 0
    fi
    log "working tree has uncommitted tracked changes; refusing to sync/build"
    log "  • commit or stash, then retry"
    log "  • or: bash scripts/daily-local-build.sh --force   (build local tree, skip sync)"
    log "  • or: bash scripts/daily-local-build.sh --no-sync"
    log "dirty files:"
    echo "$dirty_files" | sed 's/^/[daily-build]   /'
    write_state "${before_sha:-unknown}" "" "" "" "skipped_dirty_tree"
    exit 0
  fi

  log "checking out $TRACK_BRANCH..."
  git checkout "$TRACK_BRANCH"

  log "aligning $TRACK_BRANCH with $REMOTE_REF..."
  if git merge --ff-only "$REMOTE_REF"; then
    log "fast-forward from fork succeeded"
  else
    log "non-fast-forward fork history; hard-resetting to $REMOTE_REF"
    git reset --hard "$REMOTE_REF"
  fi

  merge_upstream_main
  push_to_fork

  after_sha="$(git rev-parse HEAD)"
  log "local $TRACK_BRANCH after sync: $after_sha"

  if [[ "$before_sha" == "$after_sha" && "$FORCE" -eq 0 ]]; then
    log "no new commits since last sync; skipping build"
    write_state "$after_sha" "" "" "" "skipped_up_to_date"
    exit 0
  fi

  log "updating submodules..."
  git submodule update --init --recursive

  log "installing JS dependencies..."
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
}

build_app() {
  setup_build_path

  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/load-dotenv.sh" "$REPO_ROOT/.env"
    set +a
  fi

  log "ensuring vendored cargo-tauri..."
  bash "$SCRIPT_DIR/ensure-tauri-cli.sh"

  local tauri_args bundle_dir profile_label
  if [[ "$BUILD_MODE" == "debug" ]]; then
    tauri_args=(build --debug --bundles app -- --bin OpenHuman)
    bundle_dir="$REPO_ROOT/app/src-tauri/target/debug/bundle"
    profile_label="debug"
  else
    tauri_args=(build --bundles app -- --bin OpenHuman)
    bundle_dir="$REPO_ROOT/app/src-tauri/target/release/bundle"
    profile_label="release"
  fi

  log "starting Tauri $profile_label build (app bundle only)..."
  (
    cd "$REPO_ROOT/app"
    cargo tauri "${tauri_args[@]}"
  )

  local app_path version arch dmg_dir dmg_path
  app_path="$bundle_dir/macos/OpenHuman.app"
  if [[ ! -d "$app_path" ]]; then
    log "ERROR: expected app bundle missing at $app_path"
    exit 1
  fi

  version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Contents/Info.plist")"
  arch="$(uname -m)"
  dmg_dir="$bundle_dir/dmg"
  mkdir -p "$dmg_dir"
  dmg_path="$dmg_dir/OpenHuman_${version}_${arch}.dmg"

  log "creating DMG with hdiutil (avoids Finder AppleScript timeouts)..."
  rm -f "$dmg_path"
  hdiutil create -volname "OpenHuman" -srcfolder "$app_path" -ov -format UDZO "$dmg_path" >/dev/null

  xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true

  log "linking launcher at $APPLICATIONS_LINK"
  ln -sfn "$app_path" "$APPLICATIONS_LINK"

  local sha
  sha="$(git rev-parse HEAD)"
  write_state "$sha" "$version" "$app_path" "$dmg_path" "built"
  log "done — OpenHuman $version ($sha)"
  log "app: $app_path"
  log "dmg: $dmg_path"
  log "launcher: $APPLICATIONS_LINK"
  log "fork: $REMOTE_REF"
}

main() {
  acquire_lock
  log "starting daily build (mode=$BUILD_MODE force=$FORCE dry_run=$DRY_RUN)"
  log "repo: $REPO_ROOT"
  log "log file: $LOG_FILE"

  ensure_sync_remote
  sync_from_fork
  build_app
}

main "$@"
