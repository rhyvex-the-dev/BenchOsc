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
APPDIR="$DIST_DIR/OpenBench.AppDir"
ICON_SRC="$ROOT_DIR/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"

if [ ! -x "$BUNDLE_DIR/open_bench" ] || [ ! -f "$BUNDLE_DIR/lib/libopen_bench_sim.so" ]; then
  echo "Linux release bundle or libopen_bench_sim.so missing in $BUNDLE_DIR" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
tar -C "$BUNDLE_DIR" -czf "$DIST_DIR/open-bench-linux-$ARCH.tar.gz" .

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE_DIR/." "$APPDIR/usr/bin/"
cp "$ROOT_DIR/packaging/linux/org.openbench.app.desktop" "$APPDIR/org.openbench.app.desktop"
cp "$ROOT_DIR/packaging/linux/org.openbench.app.desktop" "$APPDIR/usr/share/applications/org.openbench.app.desktop"
cp "$ICON_SRC" "$APPDIR/org.openbench.app.png"
cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/org.openbench.app.png"

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/open_bench" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if command -v appimagetool >/dev/null 2>&1; then
  APPIMAGE_ARCH="$(uname -m)"
  OUT_APPIMAGE="$DIST_DIR/OpenBench-linux-$ARCH.AppImage"
  ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 appimagetool "$APPDIR" "$OUT_APPIMAGE"
elif [ "${REQUIRE_APPIMAGE:-0}" = "1" ]; then
  echo "appimagetool not found and REQUIRE_APPIMAGE=1" >&2
  exit 1
fi
