#!/bin/sh
# Builds Retrofy for armv7 and armv7s running iOS 6, unsigned, into build/Release-iphoneos/FoxMusic.app.
# Needs FMLibrespot/build/libfmlibrespot.a (from FMLibrespot/build-ios6.sh) and ldid.
# FM_DEBUG=1 shows the errors that are normally only logged. For the iOS 4 build, see FoxMusic/iOS4/build.sh.
set -e
cd "$(dirname "$0")"

DEFINITIONS='$(inherited) FM_LIBRESPOT=1'
if [ -n "$FM_DEBUG" ]; then DEFINITIONS="$DEFINITIONS FM_DEBUG=1"; fi

# Xcode doesn't notice a new libfmlibrespot.a: libtool copies it into libFMTouch.a, which it then reuses, so the
# app keeps the old Rust code and UI. Starting clean picks it up.
rm -rf build

xcodebuild -project FoxMusic.xcodeproj -target FoxMusic -configuration Release -sdk iphoneos \
    GCC_PREPROCESSOR_DEFINITIONS="$DEFINITIONS" \
    HEADER_SEARCH_PATHS='$(inherited) $(SRCROOT)/FMLibrespot' \
    OTHER_LDFLAGS='$(inherited) -L$(SRCROOT)/FMLibrespot/build -lfmlibrespot -framework AudioToolbox -framework CoreMedia -framework OpenGLES -framework QuartzCore -framework CoreText' \
    ARCHS="armv7 armv7s" VALID_ARCHS="armv7 armv7s" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

APP=build/Release-iphoneos/FoxMusic.app
ldid -S "$APP/FoxMusic"
echo "Built $APP"
