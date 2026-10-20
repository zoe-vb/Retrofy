#!/bin/sh
# Builds libfmlibrespot.a for armv7s (iPhone 5) running iOS 6.
# Needs rustup with the nightly toolchain and rust-src: rustup component add rust-src --toolchain nightly
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

# rustc clamps the version stamped into the objects to iOS 10 and warns about it, that's expected.
# Anything std needs from iOS 10+ is provided by src/compat.rs.
# No DWARF in the C and assembly objects (ring), Xcode 4.6's dsymutil crashes on modern debug info.
export CFLAGS_armv7s_apple_ios6="-g0"
export ASMFLAGS_armv7s_apple_ios6="-g0"
# iOS 6 never delivers the kqueue EVFILT_USER event that mio wakes tokio's sleeping worker with, so work
# handed over from another thread (librespot's packets and downloads) would wait for unrelated network
# traffic. mio's pipe waker uses an ordinary read event instead.
export RUSTFLAGS="--cfg mio_unsupported_force_waker_pipe"

IPHONEOS_DEPLOYMENT_TARGET=6.0 cargo +nightly build --release \
    -Zbuild-std=std,panic_abort \
    -Zjson-target-spec \
    --target ./armv7s-apple-ios6.json

mkdir -p build
cp target/armv7s-apple-ios6/release/libfmlibrespot.a build/
echo "Built $(pwd)/build/libfmlibrespot.a"
