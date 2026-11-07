#!/bin/sh
# Builds libfmslint.a for armv7 and armv7s. Same approach and needs as FMLibrespot/build-ios6.sh.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

export CFLAGS_armv7_apple_ios6="-g0"
export ASMFLAGS_armv7_apple_ios6="-g0"
export CFLAGS_armv7s_apple_ios6="-g0"
export ASMFLAGS_armv7s_apple_ios6="-g0"

for target in armv7-apple-ios6 armv7s-apple-ios6; do
    IPHONEOS_DEPLOYMENT_TARGET=6.0 cargo +nightly build --release \
        -Zbuild-std=std,panic_abort \
        -Zjson-target-spec \
        --target "./$target.json"
done

mkdir -p build
xcrun lipo -create \
    target/armv7-apple-ios6/release/libfmslint.a \
    target/armv7s-apple-ios6/release/libfmslint.a \
    -output build/libfmslint.a
echo "Built $(pwd)/build/libfmslint.a ($(xcrun lipo -archs build/libfmslint.a))"
