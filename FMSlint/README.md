# FMSlint

An experiment: [Slint](https://slint.dev) drawing Retrofy's UI on iOS 6, through its femtovg OpenGL ES 2 renderer. Not part of the app yet. `test/` is a one screen app with a modern Now Playing over looping video.

```sh
./build-ios6.sh     # modern Mac, makes build/libfmslint.a
test/build.sh       # Xcode 4.6 machine, makes test/SlintTest.app
```

Copy `SlintTest.app` to `/Applications` and run `uicache`. The frame rate and the time a frame took are at the top left and in the log (`Slint:`).

`build/libfmslint.a` is committed so the Xcode 4.6 machine can build from a pull: rebuild and commit it after changing `src/` or `ui/`.

- UIKit keeps the event loop: a CADisplayLink calls `fm_ui_tick`, touches go through `fm_ui_touch`.
- iOS has no framebuffer 0, so `get_proc_address` hands femtovg a `glBindFramebuffer` that swaps 0 for the app's framebuffer. femtovg itself is unmodified.
- `src/compat.rs` is `FMLibrespot/src/compat.rs` plus `__sincosf_stret` and `CTFontCreateForStringWithLanguage` (iOS 7). Merged into the app, this crate would share librespot's library and its compat file, as two Rust static libraries would bring two copies of std.
- Slint reads system font files on iOS, so `ui/Inter.ttf` is built into the library.
- Slint's royalty-free license needs its `AboutSlint` widget in an About screen, or its badge on the app's download page. It covers mobile apps.
