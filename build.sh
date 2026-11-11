#!/usr/bin/env bash
# Tidemark build helper. This Mac is short on RAM and disk, so every command
# cleans up after itself on success, failure, or Ctrl-C.
#
#   ./build.sh build [--keep]   Debug build.
#   ./build.sh test  [--keep]   Run the tests on this Mac (no simulator).
#   ./build.sh run   [--keep]   Build, install to ~/Applications/Tidemark.app,
#                               launch it. Intermediates are deleted only after
#                               the app has been copied to its final location.
#   ./build.sh ios   [--keep]   Build the iPhone app, install it on the
#                               connected iPhone and launch it (never a
#                               simulator). Needs the signing team's account
#                               in Xcode › Settings › Accounts.
#   ./build.sh clean            Only clean up.
#
# --keep skips the cleanup (for debugging a build).
#
# Cleanup deletes:
#   - ~/Library/Caches/tidemark-dd, except its ModuleCache.noindex (small,
#     speeds up the next build)
#   - ~/Library/Developer/Xcode/DerivedData/Tidemark-* created by Xcode, only
#     when its info.plist points at this project (or it only holds Logs)
#   - ./build and *.profraw coverage files in this repo
# and shuts down any booted simulator and quits Simulator. It never touches
# simulator runtimes/devices, ~/Applications/Tidemark.app, app data, or source.
# It ends by printing free disk space (df -h).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd -P)"

PROJECT="Tidemark.xcodeproj"
SCHEME="Tidemark"
DD="${HOME}/Library/Caches/tidemark-dd"   # outside any cloud-synced folder
IOS_DD="${HOME}/Library/Caches/tidemark-dd-ios"
IOS_SCHEME="TidemarkiOS"
IOS_BUNDLE_ID="com.shizhengcao.Tidemark"
XCODE_DD="${HOME}/Library/Developer/Xcode/DerivedData"
DEST="platform=macOS"                       # macOS app: the Mac is the device
INSTALL_DIR="${HOME}/Applications"

KEEP=0
CMD=""
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    build|test|run|ios|clean) CMD="$arg" ;;
    *) echo "usage: $0 {build|test|run|ios|clean} [--keep]" >&2; exit 2 ;;
  esac
done
CMD="${CMD:-build}"

cleanup() {
  # Simulators: none should be running for this project, but never leave one up.
  if xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
    xcrun simctl shutdown all >/dev/null 2>&1 || true
  fi
  osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true

  # Our own DerivedData, keeping the Swift module cache.
  if [[ -d "$DD" ]]; then
    find "$DD" -mindepth 1 -maxdepth 1 ! -name ModuleCache.noindex \
      -exec rm -rf {} +
  fi

  rm -rf "$IOS_DD"

  # Xcode's default DerivedData for this project (from ⌘B/⌘R in Xcode).
  local d wp
  for d in "$XCODE_DD"/Tidemark-*; do
    [[ -d "$d" ]] || continue
    wp="$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null || true)"
    # Without info.plist, only remove a leftover that holds nothing but logs.
    if [[ "$wp" == "$ROOT/$PROJECT" ]] ||
       { [[ -z "$wp" ]] && [[ -z "$(ls -A "$d" | grep -vx -e Logs -e .DS_Store)" ]]; }; then
      rm -rf "$d"
    fi
  done

  rm -rf "$ROOT/build"
  find "$ROOT" -maxdepth 2 -name '*.profraw' -delete 2>/dev/null || true
  echo "==> cleanup done (simulators closed, intermediates deleted)"
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $KEEP -eq 1 && "$CMD" != clean ]]; then
    echo "==> --keep: skipped cleanup, intermediates are in $DD"
  else
    cleanup
  fi
  df -h "$HOME"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xb() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
    -derivedDataPath "$DD" "$@"
}

case "$CMD" in
  build)
    xb -configuration Debug build
    ;;
  test)
    xb test
    ;;
  run)
    xb -configuration Debug build
    mkdir -p "$INSTALL_DIR"
    pkill -x Tidemark >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR/Tidemark.app"
    ditto "$DD/Build/Products/Debug/Tidemark.app" "$INSTALL_DIR/Tidemark.app"
    open "$INSTALL_DIR/Tidemark.app"
    echo "==> installed and launched $INSTALL_DIR/Tidemark.app"
    ;;
  ios)
    # First connected physical iPhone or iPad.
    DEVICE="$(xcrun devicectl list devices 2>/dev/null |
      awk '/connected/ && /physical/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
    if [[ -z "$DEVICE" ]]; then
      echo "No connected iPhone found (check: xcrun devicectl list devices)." >&2
      exit 1
    fi
    xcodebuild -project "$PROJECT" -scheme "$IOS_SCHEME" -destination "id=$DEVICE" \
      -derivedDataPath "$IOS_DD" -configuration Debug -allowProvisioningUpdates build
    xcrun devicectl device install app --device "$DEVICE" \
      "$IOS_DD/Build/Products/Debug-iphoneos/TidemarkiOS.app"
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$IOS_BUNDLE_ID"
    echo "==> installed and launched on $DEVICE"
    ;;
  clean)
    : # cleanup runs from the EXIT trap
    ;;
esac
