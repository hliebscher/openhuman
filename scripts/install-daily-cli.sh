#!/usr/bin/env bash
# Install openhuman-core CLI shim from the latest daily build (or repo target/).
#
# Usage (repo root):
#   scripts/install-daily-cli.sh
#
# Prefers target/daily-build/last-build.json → core (scripts) path, else
# target/release/openhuman-core, else builds release arm64 binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

log() { echo "[daily-cli] $*"; }

# shellcheck source=scripts/daily-local-build.sh
source_daily_functions() {
  # Re-use install_cli_shims / ensure_local_bin_on_path without running a full build.
  install_cli_shims() {
    local core_binary="$1"
    local bin_dir="${HOME}/.local/bin"
    local shim="${bin_dir}/openhuman-core"
    if [[ ! -x "$core_binary" ]]; then
      log "ERROR: not executable: $core_binary"
      exit 1
    fi
    mkdir -p "$bin_dir"
    ln -sf "$core_binary" "$shim"
    ensure_local_bin_on_path
    log "installed $shim -> $core_binary"
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
    [[ -f "$config_file" ]] || touch "$config_file"
    if ! grep -q '.local/bin' "$config_file" 2>/dev/null; then
      {
        echo ""
        echo '# OpenHuman daily build — user binaries on PATH'
        echo 'export PATH="$HOME/.local/bin:$PATH"'
      } >>"$config_file"
      log "added ~/.local/bin to PATH in $config_file"
    fi
  }
}

source_daily_functions

resolve_core_binary() {
  local state="${REPO_ROOT}/target/daily-build/last-build.json"
  if [[ -f "$state" ]]; then
    local from_state
    from_state="$(python3 -c "
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
for key in ('core_binary_path', 'app_path'):
    v = d.get(key) or ''
    if key == 'app_path' and v:
        v = str(pathlib.Path(v) / 'Contents/MacOS/openhuman-core')
    if v and pathlib.Path(v).is_file():
        print(v)
        break
" "$state" 2>/dev/null || true)"
    if [[ -n "$from_state" && -x "$from_state" ]]; then
      echo "$from_state"
      return 0
    fi
  fi

  local candidates=(
    "${REPO_ROOT}/target/release/openhuman-core"
    "${REPO_ROOT}/target/aarch64-apple-darwin/release/openhuman-core"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

core="$(resolve_core_binary || true)"
if [[ -z "$core" ]]; then
  log "no openhuman-core found; building release (aarch64-apple-darwin)..."
  MACOS_TARGET="${OPENHUMAN_MACOS_TARGET:-aarch64-apple-darwin}"
  cargo build --manifest-path "$REPO_ROOT/Cargo.toml" \
    --bin openhuman-core --target "$MACOS_TARGET" --release
  core="${REPO_ROOT}/target/${MACOS_TARGET}/release/openhuman-core"
  mkdir -p "${REPO_ROOT}/target/release"
  cp -f "$core" "${REPO_ROOT}/target/release/openhuman-core"
  chmod +x "${REPO_ROOT}/target/release/openhuman-core"
  core="${REPO_ROOT}/target/release/openhuman-core"
fi

install_cli_shims "$core"
log "verify: openhuman-core --help"
if command -v openhuman-core >/dev/null 2>&1; then
  openhuman-core --help | head -5
else
  log "openhuman-core not on PATH yet — run: export PATH=\"\$HOME/.local/bin:\$PATH\""
  "${HOME}/.local/bin/openhuman-core" --help | head -5
fi
