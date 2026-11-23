#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT_DIR/rust_core/Cargo.toml"
TARGET_DIR="$ROOT_DIR/rust_core/target"
UNIVERSAL_DYLIB="$TARGET_DIR/release/libopen_bench_sim.dylib"
APP_BUNDLE="$ROOT_DIR/app/build/macos/Build/Products/Release/open_bench.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/open-bench-macos-universal.dmg"

mkdir -p "$TARGET_DIR/release"
cargo build --release --manifest-path "$MANIFEST" --target aarch64-apple-darwin
cargo build --release --manifest-path "$MANIFEST" --target x86_64-apple-darwin
lipo -create \
  "$TARGET_DIR/aarch64-apple-darwin/release/libopen_bench_sim.dylib" \
  "$TARGET_DIR/x86_64-apple-darwin/release/libopen_bench_sim.dylib" \
  -output "$UNIVERSAL_DYLIB"
install_name_tool -id "@rpath/libopen_bench_sim.dylib" "$UNIVERSAL_DYLIB"
codesign --force --sign - "$UNIVERSAL_DYLIB"

(cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter build macos --release)

EMBEDDED_DYLIB="$APP_BUNDLE/Contents/Frameworks/libopen_bench_sim.dylib"
if [ ! -f "$EMBEDDED_DYLIB" ]; then
  echo "Missing embedded universal dylib in $EMBEDDED_DYLIB" >&2
  exit 1
fi
lipo -info "$EMBEDDED_DYLIB"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_BUNDLE" "$STAGING/Open Bench.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Open Bench" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
