#!/bin/sh
# Builds Retrofy for armv6 running iOS 4.2.1 into build-ios4/Retrofy.app. Run on the machine with the old SDK:
#
#     SDK=~/iPhoneOS4.2.sdk FoxMusic/iOS4/build.sh
#
# Needs FMLibrespot/build/libfmlibrespot-armv6.a (from FMLibrespot/build-ios4.sh) and ldid.
#
# It has to be an iOS 4 SDK: FMiOS4.h declares what those lack, which would clash with an iOS 5 SDK.
#
# Newer Xcodes still compile and link armv6, they just have no armv6 libraries of their own. So the SDK
# comes from $SDK, and -nodefaultlibs leaves out clang's libclang_rt and libarclite: libgcc_s has what the
# first one provides, FMiOS4ARCRuntime.m what the second one provides.
set -e
cd "$(dirname "$0")/../.."

if [ -z "$SDK" ]; then
    echo "Set SDK to the iOS 4.2 SDK, e.g. SDK=~/iPhoneOS4.2.sdk" >&2
    exit 1
fi

CLANG="xcrun -sdk iphoneos clang -arch armv6 -miphoneos-version-min=4.2 -isysroot $SDK"
FLAGS="-Os -std=gnu99 -fobjc-exceptions -DFM_IOS4=1 -DFM_LIBRESPOT=1 -include FoxMusic/iOS4/FMiOS4.h"
# FM_DEBUG=1 shows the errors that are normally only logged.
if [ -n "$FM_DEBUG" ]; then FLAGS="$FLAGS -DFM_DEBUG=1"; fi
# The Spotify client that's actually used is the one in FoxMusicLegacyTests, it has to be found first.
INCLUDES="-IFoxMusicLegacyTests -IFMLib -IFoxMusic -IFoxMusic/iOS4 -I. -IFMLibrespot"

SOURCES="
FoxMusic/main.m
FoxMusic/FMAlertDelegate.m
FoxMusic/FMAppDelegate.m
FoxMusic/FMNowPlayingViewController.m
FoxMusic/FMPlayer.m
FoxMusic/FMSearchViewController.m
FoxMusic/FMSpotifyLibrary.m
FoxMusic/FMSpotifyPlaylistTableViewController.m
FoxMusic/FMSpotifyTrackTableViewController.m
FoxMusic/FMTableViewController.m
FoxMusic/FMTheme.m
FoxMusic/FMTrackActions.m
FoxMusic/FMViewController.m
FoxMusic/iOS4/FMiOS4.m
FoxMusic/iOS4/FMiOS4Interface.m
FoxMusic/iOS4/FMiOS4JSON.m
FMSpotifyLoginViewController.m
FoxMusicLegacyTests/FMSpotifyClient.m
FoxMusicLegacyTests/FMSpotifyDeviceAuthorizationInfo.m
FMLib/FMBase62Decoder.m
FMLib/FMMutableURLQueryDictionary.m
FMLib/FMSpotifyAlbum.m
FMLib/FMSpotifyContinuableArray.m
FMLib/FMSpotifyPlaylist.m
FMLib/FMSpotifyPlaylistArray.m
FMLib/FMSpotifyToken.m
FMLib/FMSpotifyTrack.m
FMLib/FMSpotifyTrackArray.m
FMLib/FMURLConnection.m
FMLib/FMURLConnectionDelegate.m
"

APP=build-ios4/Retrofy.app
OBJECTS=build-ios4/objects
rm -rf build-ios4
mkdir -p "$APP" "$OBJECTS"

OBJECT_FILES=""
for source in $SOURCES; do
    object="$OBJECTS/$(basename "$source" .m).o"
    echo "Compiling $source"
    $CLANG $FLAGS $INCLUDES -fobjc-arc -c "$source" -o "$object"
    OBJECT_FILES="$OBJECT_FILES $object"
done

echo "Compiling FoxMusic/iOS4/FMiOS4ARCRuntime.m"
$CLANG $FLAGS -fno-objc-arc -c FoxMusic/iOS4/FMiOS4ARCRuntime.m -o "$OBJECTS/FMiOS4ARCRuntime.o"

echo "Linking"
$CLANG $OBJECT_FILES "$OBJECTS/FMiOS4ARCRuntime.o" FMLibrespot/build/libfmlibrespot-armv6.a \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -framework AVFoundation -framework AudioToolbox -framework MediaPlayer -framework Security \
    -nodefaultlibs -lSystem -lgcc_s.1 -lobjc -o "$APP/Retrofy"

cp FoxMusic/iOS4/Info.plist "$APP/"
cp retrofy.png retrofy@2x.png FoxMusic/spotify.png FoxMusic/spotify@2x.png "$APP/"
cp FoxMusic/Default.png FoxMusic/Default@2x.png "$APP/"
ldid -S "$APP/Retrofy"

echo "Built $APP"
