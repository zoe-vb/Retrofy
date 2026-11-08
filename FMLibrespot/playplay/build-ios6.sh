#!/bin/sh
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
output="$(cd "$src/.." && pwd)/build"
cache="$output/playplay"
mkdir -p "$cache"

sdk=${IOS6_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
sdk="$(cd "$sdk" && pwd)"
if [ ! -f "$sdk/usr/lib/libSystem.dylib" ]; then
    echo "Set IOS6_SDK to an iPhoneOS 6 SDK with ARMv7 libraries." >&2
    exit 1
fi

fetch() {
    url=$1
    archive=$2
    checksum=$3
    if [ ! -f "$archive" ]; then
        curl -fLsS --retry 2 "$url" -o "$archive.part"
        printf '%s  %s\n' "$checksum" "$archive.part" | shasum -a 256 -c -
        mv "$archive.part" "$archive"
    else
        printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
    fi
}

spotiya_archive="$cache/spotiya-playplay-armv7.tar.gz"
fetch https://github.com/klockky/spotiya/releases/download/v0.9.3/spotiya-playplay-armv7.tar.gz \
    "$spotiya_archive" 87520aa52c8dc40cb636420614a2c54292c60a3e546a9885a8d91393e4617bda
python3 "$src/generate-resources.py" "$spotiya_archive" "$cache"

revision=8028ec436f2d9376525352dd38ed9ed6b9f6be10
unicorn_archive="$cache/unicorn-$revision.tar.gz"
fetch "https://codeload.github.com/unicorn-engine/unicorn/tar.gz/$revision" \
    "$unicorn_archive" 9d2a2003f0307d0fc239af439654564fe6ef17b67f7c5a39b45fad4c69d6aec2
unicorn="$cache/unicorn-$revision"
unicorn_build="$cache/unicorn-armv7"
if ! cmp -s "$src/unicorn-ios6.patch" "$unicorn/.applied-ios6.patch"; then
    rm -rf "$unicorn" "$unicorn_build"
    tar -xzf "$unicorn_archive" -C "$cache"
    patch -d "$unicorn" -p1 < "$src/unicorn-ios6.patch"
    cp "$src/unicorn-ios6.patch" "$unicorn/.applied-ios6.patch"
fi

# Unicorn's nested QEMU configure needs the target even outside CMake.
export FM_PLAYPLAY_IOS_SDK="$sdk"
cat > "$cache/clang-armv7" <<'WRAPPER'
#!/bin/sh
exec xcrun clang -target armv7-apple-ios6.0 -isysroot "$FM_PLAYPLAY_IOS_SDK" "$@"
WRAPPER
chmod +x "$cache/clang-armv7"
cmake -S "$unicorn" -B "$unicorn_build" -G Ninja \
    -DCMAKE_C_COMPILER="$cache/clang-armv7" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=armv7 \
    -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET=6.0 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="-include $src/ios6-time.h" \
    -DBUILD_SHARED_LIBS=OFF -DUNICORN_ARCH=x86 \
    -DUNICORN_BUILD_TESTS=OFF -DUNICORN_LEGACY_STATIC_ARCHIVE=ON
cmake --build "$unicorn_build" --target unicorn_archive

# The ARMv7 helper runs on both ARMv7 and ARMv7s. The app's C bridge needs both slices.
"$cache/clang-armv7" -std=gnu11 -O2 -I"$src" -I"$cache" -I"$unicorn/include" \
    "$src/ios-decoder.c" "$unicorn_build/libunicorn.a" -Wl,-ld_classic -o "$output/PlayPlayDecoder"
for arch in armv7 armv7s; do
    xcrun clang -target "$arch-apple-ios6.0" -isysroot "$sdk" -std=gnu11 -O2 -I"$cache" \
        -c "$src/ios-helper-client.c" -o "$cache/client-$arch.o"
done
xcrun libtool -static -o "$output/libplayplay-client.a" "$cache/client-armv7.o" "$cache/client-armv7s.o"
