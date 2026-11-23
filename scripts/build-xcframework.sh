#!/usr/bin/env bash
# Build traceworks-core for iOS device, iOS simulator and macOS (Apple silicon), generate the Swift
# bindings, and package app/TraceworksCore.xcframework + app/Shared/Generated/traceworks_core.swift.
# Also builds the traceworks-mcp stdio helper for the Mac app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

export IPHONEOS_DEPLOYMENT_TARGET=26.0
export MACOSX_DEPLOYMENT_TARGET=26.0
for t in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  cargo build -p traceworks-core --lib --release --target "$t"
done
cargo build -p traceworks-mcp --release --target aarch64-apple-darwin

GEN=target/uniffi-swift
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run -q -p uniffi-bindgen -- generate --library target/aarch64-apple-darwin/release/libtraceworks_core.a --language swift --out-dir "$GEN"

HDRS=target/uniffi-headers
rm -rf "$HDRS" && mkdir -p "$HDRS"
cp "$GEN"/*.h "$HDRS"/
cp "$GEN"/traceworks_coreFFI.modulemap "$HDRS"/module.modulemap

rm -rf app/TraceworksCore.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libtraceworks_core.a -headers "$HDRS" \
  -library target/aarch64-apple-ios-sim/release/libtraceworks_core.a -headers "$HDRS" \
  -library target/aarch64-apple-darwin/release/libtraceworks_core.a -headers "$HDRS" \
  -output app/TraceworksCore.xcframework

mkdir -p app/Shared/Generated app/Mac/Helpers
cp "$GEN"/traceworks_core.swift app/Shared/Generated/
cp target/aarch64-apple-darwin/release/traceworks-mcp app/Mac/Helpers/
echo "Built app/TraceworksCore.xcframework, app/Shared/Generated/traceworks_core.swift, app/Mac/Helpers/traceworks-mcp"
