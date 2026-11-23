#!/usr/bin/env sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-linux}"
JNI_DIR="$ROOT_DIR/app/android/app/src/main/jniLibs"

if [ "$TARGET" = "test" ]; then
  cargo fmt --manifest-path "$ROOT_DIR/rust_core/Cargo.toml" --check
  cargo clippy --manifest-path "$ROOT_DIR/rust_core/Cargo.toml" --all-targets -- -D warnings
  cargo test --manifest-path "$ROOT_DIR/rust_core/Cargo.toml"
  cargo build --release --manifest-path "$ROOT_DIR/rust_core/Cargo.toml"
  (cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter analyze && flutter test)
  exit 0
fi

build_android_jni() {
  if command -v cargo-ndk >/dev/null 2>&1; then
    (cd "$ROOT_DIR/rust_core" && cargo ndk \
      -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 26 -o "$JNI_DIR" build --release)
    return 0
  fi

  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
  NDK_DIR="${ANDROID_NDK_HOME:-$(ls -d "$SDK_ROOT/ndk/"* 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)}"
  if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
    echo "Android NDK not found (set ANDROID_NDK_HOME or install cargo-ndk)" >&2
    exit 1
  fi
  BIN_DIR="$(ls -d "$NDK_DIR/toolchains/llvm/prebuilt/"*/bin 2>/dev/null | head -n 1 || true)"
  if [ -z "$BIN_DIR" ] || [ ! -d "$BIN_DIR" ]; then
    echo "Android NDK LLVM bin directory not found in $NDK_DIR" >&2
    exit 1
  fi

  build_abi() {
    triple="$1"; abi="$2"; clang="$3"; env_var="$4"
    mkdir -p "$JNI_DIR/$abi"
    env "$env_var=$BIN_DIR/$clang" \
      cargo build --release --manifest-path "$ROOT_DIR/rust_core/Cargo.toml" --target "$triple"
    cp "$ROOT_DIR/rust_core/target/$triple/release/libopen_bench_sim.so" "$JNI_DIR/$abi/"
  }

  build_abi aarch64-linux-android arm64-v8a aarch64-linux-android26-clang CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
  build_abi armv7-linux-androideabi armeabi-v7a armv7a-linux-androideabi26-clang CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER
  build_abi x86_64-linux-android x86_64 x86_64-linux-android26-clang CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER
}

case "$TARGET" in
  apk)
    build_android_jni
    (cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter build apk --release --split-per-abi)
    ;;
  appbundle)
    build_android_jni
    (cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter build appbundle --release)
    ;;
  linux)
    cargo build --release --manifest-path "$ROOT_DIR/rust_core/Cargo.toml"
    (cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter build linux --release)
    "$ROOT_DIR/scripts/package_linux.sh"
    ;;
  macos)
    exec "$ROOT_DIR/scripts/package_macos.sh"
    ;;
  *)
    cargo build --release --manifest-path "$ROOT_DIR/rust_core/Cargo.toml"
    (cd "$ROOT_DIR/app" && flutter pub get && flutter gen-l10n && flutter build "$TARGET" --release)
    ;;
esac
