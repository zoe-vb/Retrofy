# FMLibrespot

Rust bridge for playing full Spotify tracks through [librespot](https://github.com/librespot-org/librespot) on iOS 6 (armv7 and armv7s, iPhone 3GS and newer). Requires Spotify Premium. Playback only: decrypted audio goes straight to the speaker and is never written to disk.

When Retrofy is built with `FM_LIBRESPOT=1`:

- **Login** uses Spotify Connect: Retrofy announces itself on the Wi-Fi (Bonjour), and picking it under Devices in the Spotify app on another phone or computer logs in. librespot saves a reusable login and logs back in with it on later launches.
- **Web API login** (playlists, search, album art) uses the user's own client ID with PKCE. It's entered on the login page and saved in the user defaults once the login finishes. Spotify limits a development mode app to 5 people, so everyone creates their own app in the developer dashboard. iOS 6's Safari can't open Spotify's login page, so Retrofy serves a page on the Wi-Fi (`http://<iPhone's IP>:8080`, `src/webapi_login.rs`): log in from a computer's browser, then paste the `http://127.0.0.1:8888/callback?code=...` address it ends up on back into the page. The redirect URI must be registered for the client ID (change it with `FMSpotifyRedirectURI`). librespot's own login5 tokens aren't used for the Web API: they belong to librespot's shared client ID, whose Web API quota is used up.
- **Other people's playlists**: since March 2026 Spotify only gives development mode apps (like the user's client ID) the tracks of the user's own playlists, other playlists answer 403. Retrofy then lists them through librespot instead (`fm_librespot_playlist_tracks`): the playlist comes from spclient and every track is looked up with librespot's metadata, 10 at a time, so long playlists fill in page by page.
- **Spotify Connect device**: once logged in, the session runs librespot's Connect device (`Spirc`) named Retrofy. It shows up in every Spotify app's device list while the app is connected, so other devices can play on it and control it, and it needs no Bonjour for that: Bonjour is only for the first login. Retrofy's own playback goes through the same device (`fm_connect_play_context`), so Spotify runs the queue, shuffle, repeat and auto next, and pressing Play on the iPhone takes over from any other device. There's one player: a second one would have Spirc reacting to playback it doesn't own.
- **Your Library, lyrics and the AI DJ** come from librespot too, as they aren't in the Web API for a development mode app: `fm_librespot_rootlist` has Spotify's own playlists (Daily Mix, Your Top Songs and so on), `fm_librespot_lyrics` the lyrics, and `fm_librespot_dj_session` the DJ's picks. The DJ's commentary is text on the tracks: Spotify's apps speak it with their own text to speech, its audio isn't part of the session.
- **Playback**: the Play button on a track plays the full song through librespot. If that fails, it falls back to the 30 second preview.

The login and the device ID live in `Library/librespot` (`/var/mobile/Library/librespot` for an app in `/Applications`). Delete that folder to log out. No audio is ever cached.

## Building the library (modern Mac)

```sh
IOS6_SDK=/path/to/iPhoneOS6.1.sdk FMLibrespot/build-ios6.sh
```

Needs a modern Xcode toolchain, the iPhoneOS 6 SDK, rustup with nightly and `rust-src`,
Python 3, CMake and Ninja. The script produces `libfmlibrespot.a`, `libplayplay-client.a`
and `PlayPlayDecoder` under `FMLibrespot/build/`.

The build pins the [Spotiya v0.9.3 PlayPlay add-on](https://github.com/klockky/spotiya/releases/tag/v0.9.3)
and the [Unicorn source revision](https://github.com/unicorn-engine/unicorn/tree/8028ec436f2d9376525352dd38ed9ed6b9f6be10).
The archives and generated decoder resources are cached under `FMLibrespot/build/playplay/`.
Spotiya's wrapper and its license are in `FMLibrespot/playplay/`. The guest image comes from
Spotify for Android and has separate provenance documented in Spotiya's release.

With `PLAYPLAY_TEST=1` set when running this script, streamed tracks use PlayPlay v5 directly.
Without the flag, FoxMusic tries legacy first and requests PlayPlay only on an explicit refusal.

How it gets around Rust not supporting iOS 6:

- `armv7s-apple-ios6.json` is rustc's `armv7s-apple-ios` target with `has-thread-local` off, because native thread-locals need iOS 9's dyld. std falls back to pthread keys.
- `armv7-apple-ios6.json` is the same target for armv7: `cortex-a8` with VFPv3 and NEON instead of `swift` with VFPv4, so it runs on every armv7 iOS 6 device. These have no hardware divide, so 32-bit division calls `__divsi3` and friends in libSystem. `build-ios6.sh` builds both and joins them with `lipo`.
- std is rebuilt for that target with `-Zbuild-std`.
- `src/compat.rs` provides functions that std, ring or the compiler use but iOS 6 doesn't have: `clock_gettime` and `CCRandomGenerateBytes` (iOS 10 and 8), `__sincos_stret` and `__exp10` (iOS 7), `__floatuntidf`, `__floatuntisf` and `dirfd`.
- rustc stamps the objects with iOS 10.0 no matter what, so the old linker may warn "built for newer iOS version". That warning is expected.
- `patches/` holds sysinfo, ring and dns-sd with small iOS fixes: ring gets its 32-bit Arm assembly back on Apple platforms. See `patches/README.md`.
- `vergen` is pinned to 9.0.6 in `Cargo.lock`, 9.1 breaks librespot-core's build script.
- TLS uses rustls with bundled root certificates, since iOS 6's are outdated.
- mio is built with `--cfg mio_unsupported_force_waker_pipe`: iOS 6 never delivers the kqueue `EVFILT_USER` event mio normally wakes tokio with. `fm_librespot_init` checks wake-ups and logs the result, and if they still don't work it wakes the runtime every 10 ms instead.

## armv6 and iOS 4.2.1 (experimental)

`build-ios4.sh` builds `build/libfmlibrespot-armv6.a` for the iPhone 3G and iPod touch 2nd generation. It plays music on iOS 4.2.1 on an armv6 device, tested with `ios4-test/`, a one screen test app. The Retrofy app itself is built with `FoxMusic/iOS4/build.sh`: see the comments in that script and in `FoxMusic/iOS4/FMiOS4.h`.

Xcode 4.6 still compiles and links armv6, it only lacks armv6 libraries, so this works with the iOS 4.2 SDK and clang's default libraries turned off:

```sh
cd FMLibrespot/ios4-test
SDK=~/iPhoneOS4.2.sdk
mkdir -p RetrofyTest.app
xcrun -sdk iphoneos clang -arch armv6 -miphoneos-version-min=4.2 -isysroot "$SDK" -I.. -O2 main.m \
    ../build/libfmlibrespot-armv6.a -framework UIKit -framework Foundation -framework AVFoundation \
    -framework AudioToolbox -nodefaultlibs -lSystem -lgcc_s.1 -lobjc -o RetrofyTest.app/RetrofyTest
cp Info.plist RetrofyTest.app/
ldid -S RetrofyTest.app/RetrofyTest
```

Copy `RetrofyTest.app` to `/Applications` on a jailbroken device and run `uicache`. Tap Pair and pick "Retrofy Test" in the Spotify app, then Play. Undefined symbols when linking, or a dyld error at launch, are functions iOS 4.2.1 doesn't have, which need a replacement in `src/compat.rs`. What to look for on the device: how long the first track takes to start, whether the audio drops out, and whether the app gets killed for using too much memory.

## Code

- `src/player.rs`: the C API in `fmlibrespot.h`: one process-wide session and its Connect device, Spotify Connect discovery, saved login, Web API tokens, playlist listing and playback.
- `src/http.rs`: a small blocking HTTPS client on rustls (`fm_https_request`), for accounts.spotify.com.
- `src/audio.rs`: Audio Queue output fed by a half second ring buffer.
- `src/compat.rs`: the iOS 6 replacements listed above, and `arc4random_buf` for iOS 4.2.1.
- `src/lib.rs`: `fm_librespot_self_test`, logged at launch.

## Building Retrofy with it (old Xcode)

Copy the three build outputs to `FMLibrespot/build/` on the old Xcode machine and run
`./build.sh` from the repository root. It links both ARM slices and copies and signs the
ARMv7 decoder in `build/Release-iphoneos/FoxMusic.app`.
Use `FM_SIGN=0 ./build.sh` if you sign the app and helper on a separate machine.

If linking fails with an undefined symbol, that function is missing on iOS 6 and needs a replacement in `src/compat.rs`.
