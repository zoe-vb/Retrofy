#!/bin/sh
# Builds Retrofy for armv7 and armv7s running iOS 6 into build/Release-iphoneos/FoxMusic.app.
# Needs the outputs of FMLibrespot/build-ios6.sh and ldid (or FM_SIGN=0).
# FM_DEBUG=1 shows the errors that are normally only logged. For the iOS 4 build, see FoxMusic/iOS4/build.sh.
set -e
cd "$(dirname "$0")"

DEFINITIONS='$(inherited) FM_LIBRESPOT=1'
if [ -n "$FM_DEBUG" ]; then DEFINITIONS="$DEFINITIONS FM_DEBUG=1"; fi

for input in libfmlibrespot.a libplayplay-client.a PlayPlayDecoder; do
    if [ ! -f "FMLibrespot/build/$input" ]; then
        echo "Missing $input. Run FMLibrespot/build-ios6.sh first." >&2
        exit 1
    fi
done

# Xcode reuses libFMTouch.a after a Rust library change unless the build starts clean.
rm -rf build
xcodebuild -project FoxMusic.xcodeproj -target FoxMusic -configuration Release -sdk iphoneos \
    GCC_PREPROCESSOR_DEFINITIONS="$DEFINITIONS" \
    HEADER_SEARCH_PATHS='$(inherited) $(SRCROOT)/FMLibrespot' \
    OTHER_LDFLAGS='$(inherited) -L$(SRCROOT)/FMLibrespot/build -lfmlibrespot -lplayplay-client -framework AudioToolbox -framework CoreMedia -framework OpenGLES -framework QuartzCore -framework CoreText' \
    ARCHS="armv7 armv7s" VALID_ARCHS="armv7 armv7s" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

APP=build/Release-iphoneos/FoxMusic.app
cp FMLibrespot/build/PlayPlayDecoder "$APP/PlayPlayDecoder"
if [ "${FM_SIGN:-1}" != 0 ]; then
    ldid -S "$APP/PlayPlayDecoder"
    ldid -S "$APP/FoxMusic"
fi
file "$APP/FoxMusic"
echo "Built $APP"
