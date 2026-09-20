#!/usr/bin/env bash
# Remove only disposable host-side files. Safe to call before or after launch.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_DIR/data"
BUILD_DIR="${BUILD_DIR:-$DATA_DIR/build}"
SHARE_DIR="$PROJECT_DIR/share"
LOG_DIR="$PROJECT_DIR/log"
mode="${1:-all}"

if [ "$(uname -s)" != "Linux" ]; then
  echo "[-] clean.sh runs on Linux only." >&2
  exit 1
fi

case "$mode" in
  before-build|after-build|before-run|after-run|all) ;;
  -h|--help)
    cat <<'EOF'
Usage: ./scripts/clean.sh [before-build|after-build|before-run|after-run|all]

Deletes only temporary launch artifacts, interrupted downloads, and core
dumps. Any accidentally-created root-level *.log file is moved into log/.
EOF
    exit 0
    ;;
  *)
    echo "[-] Unknown cleanup mode: $mode" >&2
    exit 2
    ;;
esac

mkdir -p "$LOG_DIR"

move_root_logs() {
  shopt -s nullglob
  local file stamp destination
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for file in "$PROJECT_DIR"/*.log; do
    destination="$LOG_DIR/legacy-${stamp}-$(basename "$file")"
    mv -- "$file" "$destination"
    echo "[+] Moved misplaced log to ${destination#$PROJECT_DIR/}"
  done
}

remove_file_if_present() {
  local file="$1"
  [ -e "$file" ] || [ -L "$file" ] || return 0
  rm -f -- "$file"
  echo "[+] Removed ${file#$PROJECT_DIR/}"
}

remove_partial_downloads_and_cores() {
  shopt -s nullglob
  local file
  for file in "$BUILD_DIR"/*.part "$PROJECT_DIR"/*.part \
              "$BUILD_DIR"/core "$BUILD_DIR"/core.* \
              "$PROJECT_DIR"/core "$PROJECT_DIR"/core.*; do
    remove_file_if_present "$file"
  done
}

remove_staged_launch_artifacts() {
  local staging_dir="$SHARE_DIR/.launch-artifacts"
  [ -e "$staging_dir" ] || return 0
  rm -rf -- "$staging_dir"
  echo "[+] Removed share/.launch-artifacts"
}

move_root_logs
remove_partial_downloads_and_cores

case "$mode" in
  before-run|after-run|all) remove_staged_launch_artifacts ;;
esac
