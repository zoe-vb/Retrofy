#!/bin/sh
# Builds SlintTest.app for iOS 6 with Xcode 4.6. Needs ../build/libfmslint.a and ldid.
set -e
cd "$(dirname "$0")"

mkdir -p SlintTest.app
xcrun -sdk iphoneos clang -arch armv7 -arch armv7s -miphoneos-version-min=6.0 -fobjc-arc -O2 main.m \
    ../build/libfmslint.a -framework UIKit -framework Foundation -framework QuartzCore -framework OpenGLES \
    -framework AVFoundation -framework CoreMedia -framework CoreText -framework CoreGraphics \
    -framework CoreFoundation -liconv -o SlintTest.app/SlintTest
cp Info.plist test.mp4 Default-568h@2x.png SlintTest.app/
ldid -S SlintTest.app/SlintTest
echo "Built $(pwd)/SlintTest.app"
