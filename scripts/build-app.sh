#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
# Sign and archive outside synced/File Provider folders: those services can
# reattach FinderInfo between metadata cleanup and codesign verification.
STAGING_DIR="$(mktemp -d /private/tmp/ghost-recorder-build.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Ghost Recorder.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PWD/dist"
cp -X "$BIN_DIR/GhostRecorder" "$APP_DIR/Contents/MacOS/GhostRecorder"
cp -X resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --sign - --identifier com.gavinzdarko.GhostRecorder "$APP_DIR"
codesign --verify --strict "$APP_DIR"
ARCHIVE="$PWD/dist/Ghost-Recorder-macOS-$(uname -m).zip"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$ARCHIVE"
mkdir -p "$STAGING_DIR/verify"
ditto -x -k "$ARCHIVE" "$STAGING_DIR/verify"
codesign --verify --deep --strict "$STAGING_DIR/verify/Ghost Recorder.app"
# A convenient local copy. File Provider may decorate this copy with metadata;
# the verified archive above is the portable deliverable.
ditto --norsrc --noextattr "$APP_DIR" "$PWD/dist/Ghost Recorder.app"
xattr -d com.apple.FinderInfo "$PWD/dist/Ghost Recorder.app" 2>/dev/null || true
printf 'Built: %s\n' "$PWD/dist/Ghost Recorder.app"
printf 'Verified archive: %s\n' "$ARCHIVE"
