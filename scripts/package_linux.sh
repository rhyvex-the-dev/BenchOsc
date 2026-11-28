#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${1:-}" ]; then
  ARCH="$1"
else
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="x64" ;;
  esac
fi
BUNDLE_DIR="$ROOT_DIR/app/build/linux/$ARCH/release/bundle"
DIST_DIR="$ROOT_DIR/dist"
APPDIR="$DIST_DIR/BenchOsc.AppDir"
ICON_SRC="$ROOT_DIR/packaging/linux/org.benchosc.app.png"
if [ ! -f "$ICON_SRC" ]; then
  ICON_SRC="$ROOT_DIR/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"
fi

if [ ! -x "$BUNDLE_DIR/benchosc" ] || [ ! -f "$BUNDLE_DIR/lib/libbenchosc_sim.so" ]; then
  echo "Linux release bundle or libbenchosc_sim.so missing in $BUNDLE_DIR" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
tar -C "$BUNDLE_DIR" -czf "$DIST_DIR/benchosc-linux-$ARCH.tar.gz" .

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE_DIR/." "$APPDIR/usr/bin/"
cp "$ROOT_DIR/packaging/linux/org.benchosc.app.desktop" "$APPDIR/org.benchosc.app.desktop"
cp "$ROOT_DIR/packaging/linux/org.benchosc.app.desktop" "$APPDIR/usr/share/applications/org.benchosc.app.desktop"
cp "$ICON_SRC" "$APPDIR/org.benchosc.app.png"
cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/org.benchosc.app.png"

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/benchosc" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if command -v appimagetool >/dev/null 2>&1; then
  case "$ARCH" in
    arm64|aarch64) APPIMAGE_ARCH="aarch64" ;;
    *) APPIMAGE_ARCH="x86_64" ;;
  esac
  OUT_APPIMAGE="$DIST_DIR/BenchOsc-linux-$ARCH.AppImage"
  ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 appimagetool "$APPDIR" "$OUT_APPIMAGE"
elif [ "${REQUIRE_APPIMAGE:-0}" = "1" ]; then
  echo "appimagetool not found and REQUIRE_APPIMAGE=1" >&2
  exit 1
fi
