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
#   OPENHUMAN_MACOS_TARGET=aarch64-apple-darwin  Apple Silicon only (default; no Intel)
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
APPLICATIONS_LINK="/Applications/OpenHuman.app"
# Daily builds are Apple Silicon (arm64) only — no x86_64 / universal artifacts.
MACOS_TARGET="${OPENHUMAN_MACOS_TARGET:-aarch64-apple-darwin}"
ARCH_LABEL="arm64"

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

log() { echo "[daily-build] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

check_sudo_access() {
  if [[ "$APPLICATIONS_LINK" == /Applications/* ]]; then
    log "checking sudo access for /Applications..."
    if ! sudo -n true 2>/dev/null; then
      echo "[daily-build] sudo required to copy app to $APPLICATIONS_LINK"
      sudo -v
    fi
  fi
}

acquire_lock() {
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    log "another daily build appears to be running (lock: $LOCK_FILE); exiting"
    exit 0
  fi
  trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT
}

write_state() {
  local sha="$1" version="$2" app_path="$3" dmg_path="$4" status="$5" core_path="${6:-}" cli_shim="${7:-}"
  cat >"$STATE_DIR/last-build.json" <<EOF
{
  "status": "$status",
  "sha": "$sha",
  "version": "$version",
  "build_mode": "$BUILD_MODE",
  "macos_target": "$MACOS_TARGET",
  "app_path": "$app_path",
  "dmg_path": "$dmg_path",
  "core_binary_path": "$core_path",
  "cli_shim_path": "$cli_shim",
  "applications_link": "$APPLICATIONS_LINK",
  "sync_remote": "$SYNC_REMOTE",
  "track_branch": "$TRACK_BRANCH",
  "remote_ref": "$REMOTE_REF",
  "merge_upstream": "$MERGE_UPSTREAM",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

ensure_local_bin_on_path() {
  local bin_dir="${HOME}/.local/bin"
  if echo ":${PATH}:" | grep -q ":${bin_dir}:"; then
    return 0
  fi
  local shell_name config_file
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "${shell_name}" in
    zsh) config_file="${HOME}/.zshrc" ;;
    bash) config_file="${HOME}/.bashrc" ;;
    *) config_file="${HOME}/.profile" ;;
  esac
  if [[ ! -f "$config_file" ]]; then
    touch "$config_file"
  fi
  if ! grep -q '.local/bin' "$config_file" 2>/dev/null; then
    {
      echo ""
      echo '# OpenHuman daily build — user binaries on PATH'
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >>"$config_file"
    log "added ~/.local/bin to PATH via $config_file (open a new shell or: source $config_file)"
  fi
}

# Symlink openhuman-core into ~/.local/bin for terminal CLI + MCP config snippets.
install_cli_shims() {
  local core_binary="$1"
  local bin_dir="${HOME}/.local/bin"
  local shim="${bin_dir}/openhuman-core"

  if [[ ! -x "$core_binary" ]]; then
    log "ERROR: cannot install CLI shim — not executable: $core_binary"
    exit 1
  fi

  mkdir -p "$bin_dir"
  ln -sf "$core_binary" "$shim"
  ensure_local_bin_on_path
  log "CLI: $shim -> $core_binary" >&2
  printf '%s\n' "$shim"
}

require_apple_silicon_host() {
  local host_arch
  host_arch="$(uname -m)"
  if [[ "$MACOS_TARGET" != "aarch64-apple-darwin" ]]; then
    log "ERROR: daily build only supports OPENHUMAN_MACOS_TARGET=aarch64-apple-darwin (got $MACOS_TARGET)"
    exit 1
  fi
  if [[ "$host_arch" != "arm64" ]]; then
    log "ERROR: daily build is Apple Silicon only; this host is $host_arch"
    log "Intel/universal macOS bundles are not produced by this script."
    exit 1
  fi
  log "macOS target: $MACOS_TARGET ($ARCH_LABEL only)"
}

tauri_target_dir() {
  local profile="$1"
  echo "$REPO_ROOT/app/src-tauri/target/${MACOS_TARGET}/${profile}"
}

repo_core_target_dir() {
  local profile="$1"
  echo "$REPO_ROOT/target/${MACOS_TARGET}/${profile}"
}

repo_core_staging_dir() {
  local profile="$1"
  echo "$REPO_ROOT/target/${profile}"
}

build_openhuman_core() {
  local profile="$1"
  local cargo_profile_flag=()
  if [[ "$profile" == "release" ]]; then
    cargo_profile_flag=(--release)
  fi

  log "building openhuman-core ($MACOS_TARGET, $profile)..." >&2
  cargo build --manifest-path "$REPO_ROOT/Cargo.toml" \
    --bin openhuman-core \
    --target "$MACOS_TARGET" \
    "${cargo_profile_flag[@]}"

  local built_core staging_core
  built_core="$(repo_core_target_dir "$profile")/openhuman-core"
  staging_core="$(repo_core_staging_dir "$profile")/openhuman-core"

  if [[ ! -x "$built_core" ]]; then
    log "ERROR: openhuman-core missing at $built_core"
    exit 1
  fi

  mkdir -p "$(dirname "$staging_core")"
  cp -f "$built_core" "$staging_core"
  chmod +x "$staging_core"
  log "staged openhuman-core for CLI/scripts: $staging_core" >&2
  printf '%s\n' "$built_core"
}

stage_core_into_app_bundle() {
  local profile="$1" app_path="$2"
  local built_core app_core
  built_core="$(build_openhuman_core "$profile")"
  app_core="$app_path/Contents/MacOS/openhuman-core"

  cp -f "$built_core" "$app_core"
  chmod +x "$app_core"
  log "installed openhuman-core into app bundle: $app_core" >&2
  printf '%s\n' "$app_core"
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
  require_apple_silicon_host
  setup_build_path

  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/load-dotenv.sh" "$REPO_ROOT/.env"
    set +a
  fi

  log "ensuring vendored cargo-tauri..."
  bash "$SCRIPT_DIR/ensure-tauri-cli.sh"

  local tauri_args bundle_dir profile_label profile_name
  if [[ "$BUILD_MODE" == "debug" ]]; then
    tauri_args=(build --debug --target "$MACOS_TARGET" --bundles app -- --bin OpenHuman)
    profile_name="debug"
    profile_label="debug"
  else
    tauri_args=(build --target "$MACOS_TARGET" --bundles app -- --bin OpenHuman)
    profile_name="release"
    profile_label="release"
  fi
  bundle_dir="$(tauri_target_dir "$profile_name")/bundle"

  log "starting Tauri $profile_label build ($MACOS_TARGET, app bundle only)..."
  (
    cd "$REPO_ROOT/app"
    cargo tauri "${tauri_args[@]}"
  )

  local app_path version dmg_dir dmg_path core_in_app
  app_path="$bundle_dir/macos/OpenHuman.app"
  if [[ ! -d "$app_path" ]]; then
    log "ERROR: expected app bundle missing at $app_path"
    exit 1
  fi

  core_in_app="$(stage_core_into_app_bundle "$profile_name" "$app_path")"
  local staging_core cli_shim
  staging_core="$(repo_core_staging_dir "$profile_name")/openhuman-core"
  cli_shim="$(install_cli_shims "$staging_core")"

  version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Contents/Info.plist")"
  dmg_dir="$bundle_dir/dmg"
  mkdir -p "$dmg_dir"
  dmg_path="$dmg_dir/OpenHuman_${version}_${ARCH_LABEL}.dmg"

  log "creating DMG with hdiutil (avoids Finder AppleScript timeouts)..."
  rm -f "$dmg_path"
  hdiutil create -volname "OpenHuman" -srcfolder "$app_path" -ov -format UDZO "$dmg_path" >/dev/null

  xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true

  log "copying launcher to $APPLICATIONS_LINK"
  if [[ "$APPLICATIONS_LINK" == /Applications/* ]]; then
    sudo rm -rf "$APPLICATIONS_LINK"
    sudo cp -R "$app_path" "$(dirname "$APPLICATIONS_LINK")"
    sudo xattr -dr com.apple.quarantine "$APPLICATIONS_LINK" 2>/dev/null || true
  else
    rm -rf "$APPLICATIONS_LINK"
    cp -R "$app_path" "$APPLICATIONS_LINK"
    xattr -dr com.apple.quarantine "$APPLICATIONS_LINK" 2>/dev/null || true
  fi

  local sha
  sha="$(git rev-parse HEAD)"
  write_state "$sha" "$version" "$app_path" "$dmg_path" "built" "$core_in_app" "$cli_shim"
  log "done — OpenHuman $version ($sha) [$ARCH_LABEL]"
  log "app: $app_path"
  log "core: $core_in_app"
  log "core (scripts): $staging_core"
  log "cli: $cli_shim  (openhuman-core --help)"
  log "dmg: $dmg_path"
  log "launcher: $APPLICATIONS_LINK"
  log "fork: $REMOTE_REF"
}

cleanup_build_artifacts() {
  log "cleaning up build artifacts..."
  "$SCRIPT_DIR/cleanup-builds.sh" 2>&1 | sed 's/^/[cleanup] /'
}

main() {
  acquire_lock
  check_sudo_access
  log "starting daily build (mode=$BUILD_MODE force=$FORCE dry_run=$DRY_RUN)"
  log "repo: $REPO_ROOT"
  log "log file: $LOG_FILE"

  ensure_sync_remote
  sync_from_fork
  build_app
  cleanup_build_artifacts
}

main "$@"
