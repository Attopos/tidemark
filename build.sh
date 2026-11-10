#!/usr/bin/env bash
# Tidemark build helper.
#
#   ./build.sh build   Build Debug, then delete build intermediates.
#   ./build.sh test    Run the test suite on this Mac, then delete intermediates.
#   ./build.sh run     Build, install to ~/Applications/Tidemark.app, launch it,
#                      then delete intermediates.
#   ./build.sh clean   Close simulators and delete build intermediates only.
#
# Rules: no simulators (this is a macOS app, it runs on the Mac itself); after
# every build or test, any running simulator is shut down and DerivedData /
# coverage files are removed, whether the step passed or failed.
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Tidemark.xcodeproj"
SCHEME="Tidemark"
DD="${HOME}/Library/Caches/tidemark-dd"   # outside any cloud-synced folder
DEST="platform=macOS"
INSTALL_DIR="${HOME}/Applications"

cleanup() {
  # Close any simulator that may have been started (none should be).
  if xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
    xcrun simctl shutdown all >/dev/null 2>&1 || true
  fi
  pkill -x Simulator >/dev/null 2>&1 || true
  # Delete build intermediates.
  rm -rf "$DD" build
  find . -maxdepth 2 -name '*.profraw' -delete 2>/dev/null || true
  echo "==> simulators closed, build intermediates deleted"
}

xb() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
    -derivedDataPath "$DD" "$@"
}

cmd="${1:-build}"
case "$cmd" in
  build)
    trap cleanup EXIT
    xb -configuration Debug build
    ;;
  test)
    trap cleanup EXIT
    xb test
    ;;
  run)
    trap cleanup EXIT
    xb -configuration Debug build
    mkdir -p "$INSTALL_DIR"
    pkill -x Tidemark >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR/Tidemark.app"
    ditto "$DD/Build/Products/Debug/Tidemark.app" "$INSTALL_DIR/Tidemark.app"
    open "$INSTALL_DIR/Tidemark.app"
    echo "==> installed and launched $INSTALL_DIR/Tidemark.app"
    ;;
  clean)
    cleanup
    ;;
  *)
    echo "usage: $0 {build|test|run|clean}" >&2
    exit 2
    ;;
esac
