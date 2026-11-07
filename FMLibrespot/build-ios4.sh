#!/bin/sh
# Builds build/libfmlibrespot-armv6.a for armv6 (iPhone 3G, iPod touch 2nd generation) running iOS 4.2.1.
# Same requirements as build-ios6.sh. Linking it needs a toolchain with armv6: Xcode 4.4 or older.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

# See build-ios6.sh for what these are for.
export CFLAGS_armv6_apple_ios4="-g0"
export ASMFLAGS_armv6_apple_ios4="-g0"
# fm_ios4 turns on the extra replacements in src/compat.rs.
export RUSTFLAGS="--cfg mio_unsupported_force_waker_pipe --cfg fm_ios4 --check-cfg=cfg(fm_ios4)"

IPHONEOS_DEPLOYMENT_TARGET=4.2 cargo +nightly build --release \
    -Zbuild-std=std,panic_abort \
    -Zjson-target-spec \
    --target ./armv6-apple-ios4.json

mkdir -p build
cp target/armv6-apple-ios4/release/libfmlibrespot.a build/libfmlibrespot-armv6.a
echo "Built $(pwd)/build/libfmlibrespot-armv6.a"
