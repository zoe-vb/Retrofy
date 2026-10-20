# FMLibrespot

Rust bridge for playing full Spotify tracks through [librespot](https://github.com/librespot-org/librespot) on iOS 6 (armv7s, iPhone 5). Requires Spotify Premium. Playback only: decrypted audio goes straight to the speaker and is never written to disk.

When FoxMusic is built with `FM_LIBRESPOT=1`:

- **Login** uses Spotify Connect: FoxMusic announces itself on the Wi-Fi (Bonjour), and picking it under Devices in the Spotify app on another phone or computer logs in. librespot saves a reusable login and logs back in with it on later launches.
- **Web API login** (playlists, search, album art) uses FoxMusic's own client ID (`FMSpotifyClientID` in the Info.plist) with PKCE, so it gets that app's own quota. iOS 6's Safari can't open Spotify's login page, so FoxMusic serves a page on the Wi-Fi (`http://<iPhone's IP>:8080`, `src/webapi_login.rs`): log in from a computer's browser, then paste the `http://127.0.0.1:8888/callback?code=...` address it ends up on back into the page. The redirect URI must be registered for the client ID (change it with `FMSpotifyRedirectURI`). librespot's own login5 tokens aren't used for the Web API: they belong to librespot's shared client ID, whose Web API quota is used up.
- **Playback**: the Play button on a track plays the full song through librespot. If that fails, it falls back to the 30 second preview.

The login and the device ID live in `Library/librespot` (`/var/mobile/Library/librespot` for an app in `/Applications`). Delete that folder to log out. No audio is ever cached.

## Building the library (modern Mac)

```sh
FMLibrespot/build-ios6.sh
```

Produces `FMLibrespot/build/libfmlibrespot.a`. Needs rustup with nightly and `rust-src`.

How it gets around Rust not supporting iOS 6:

- `armv7s-apple-ios6.json` is rustc's `armv7s-apple-ios` target with `has-thread-local` off, because native thread-locals need iOS 9's dyld. std falls back to pthread keys.
- std is rebuilt for that target with `-Zbuild-std`.
- `src/compat.rs` provides functions that std, ring or the compiler use but iOS 6 doesn't have: `clock_gettime` and `CCRandomGenerateBytes` (iOS 10 and 8), `__sincos_stret` and `__exp10` (iOS 7), `__floatuntidf`, `__floatuntisf` and `dirfd`.
- rustc stamps the objects with iOS 10.0 no matter what, so the old linker may warn "built for newer iOS version". That warning is expected.
- `patches/` holds sysinfo, ring and dns-sd with small iOS fixes: ring gets its 32-bit Arm assembly back on Apple platforms. See `patches/README.md`.
- `vergen` is pinned to 9.0.6 in `Cargo.lock`, 9.1 breaks librespot-core's build script.
- TLS uses rustls with bundled root certificates, since iOS 6's are outdated.
- mio is built with `--cfg mio_unsupported_force_waker_pipe`: iOS 6 never delivers the kqueue `EVFILT_USER` event mio normally wakes tokio with. `fm_librespot_init` checks wake-ups and logs the result, and if they still don't work it wakes the runtime every 10 ms instead.

## Code

- `src/player.rs`: the C API in `fmlibrespot.h`: one process-wide session, Spotify Connect discovery, saved login, Web API tokens and playback.
- `src/http.rs`: a small blocking HTTPS client on rustls (`fm_https_request`), for accounts.spotify.com.
- `src/audio.rs`: Audio Queue output fed by a half second ring buffer.
- `src/compat.rs`: the iOS 6 replacements listed above.
- `src/lib.rs`: `fm_librespot_self_test`, logged at launch.

## Building FoxMusic with it (old Xcode)

Copy `libfmlibrespot.a` to `FMLibrespot/build/` on the build machine, then add these to the `xcodebuild` command line:

```
GCC_PREPROCESSOR_DEFINITIONS='$(inherited) FM_LIBRESPOT=1'
HEADER_SEARCH_PATHS='$(inherited) $(SRCROOT)/FMLibrespot'
OTHER_LDFLAGS='$(inherited) -L$(SRCROOT)/FMLibrespot/build -lfmlibrespot -framework AudioToolbox'
ARCHS=armv7s VALID_ARCHS=armv7s ONLY_ACTIVE_ARCH=NO
```

The library only contains armv7s code, so armv7 builds fail to link. If linking fails with an undefined symbol, that function is missing on iOS 6 and needs a replacement in `src/compat.rs`.
