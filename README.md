# BenchOsc

Cross-platform interactive circuit simulator inspired by Electronics Workbench (`rust_core/` Modified Nodal Analysis engine + `app/` Flutter UI via `dart:ffi`).

## Architecture
- **`rust_core/`**: Pure-Rust MNA DC / transient (Backward Euler, Trapezoidal, Gear-2) / AC frequency-sweep / hybrid dense+sparse LU solver, 4-state digital evaluator, subcircuit/SPICE `.cir` exporter (`ob_sim_export_cir`), Hann FFT + THD, and Quine-McCluskey logic minimizer.
- **`app/`**: Flutter desktop & mobile UI featuring interactive schematic capture, obstacle-avoiding Manhattan wire auto-routing, live current flow animation, LED/lamp luminance, and 8 virtual instruments (4-ch Oscilloscope, Multimeter Pro, Bode Plotter, Logic Converter, Logic Analyzer with SPI/I2C/UART decoders, DC Sweep / Monte Carlo, Word Generator, Spectrum Analyzer).

## Build & Verify
```bash
# Rust engine tests, strict lint, and release native library
cargo test --manifest-path rust_core/Cargo.toml
cargo clippy --manifest-path rust_core/Cargo.toml --all-targets -- -D warnings
cargo build --release --manifest-path rust_core/Cargo.toml

# Flutter l10n, analyzer, and tests
cd app && flutter gen-l10n && flutter analyze && flutter test

# Cross-platform release packaging
./scripts/build_all.sh linux       # dist/benchosc-linux-x64.tar.gz (+ AppImage if appimagetool installed)
./scripts/build_all.sh macos       # dist/benchosc-macos-universal.dmg
./scripts/build_all.sh apk         # split-ABI APKs (or `appbundle` for Play Store AAB)
# Windows PowerShell: ./scripts/build_windows.ps1 -> dist/benchosc-windows-x64.zip
```

## Keyboard Shortcuts
- `Space`: Run / Pause simulation (`Single Step` appears when paused)
- `R`: Rotate selected component 90°
- `F`: Flip selected component horizontally
- `Del` / `Backspace`: Delete selected component(s)
- `Ctrl+Z` / `Ctrl+Y`: Undo / Redo
- `Ctrl+C` / `Ctrl+V` / `Ctrl+D`: Copy / Paste / Duplicate
- `?`: Open Help & Shortcuts dialog

## License
Licensed under the Business Source License 1.1 (`BUSL-1.1`). See [LICENSE](LICENSE) for details.
