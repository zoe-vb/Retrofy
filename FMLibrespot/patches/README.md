# Vendored crate patches

All four are used through `[patch.crates-io]` in `../Cargo.toml`. Everything else is upstream.

## sysinfo 0.36.1

`src/unix/apple/process.rs`: `ProcessInner::open_files` calls libproc's `proc_pidinfo`, which the libc
crate only defines for macOS, so it doesn't compile for iOS. On anything but macOS it now returns `None`.
librespot only uses sysinfo for the OS name and version.

## ring 0.17.14

ring has no assembly for 32-bit Arm on Apple platforms, and `include/ring-core/target.h` deliberately
turns it off there (the last iOS with 32-bit Arm was iOS 10). ring's Rust code still calls the assembly
routines on that target, so linking fails with undefined `_ring_core_0_17_14__*` symbols.

- `build.rs`: added an `ios32` entry for `APPLE_ABI` + `ARM` to `ASM_TARGETS`.
- `include/ring-core/target.h`: removed the block that defines `OPENSSL_NO_ASM` for Apple + Arm.
- `pregenerated/*-ios32.S`: generated from ring's own perlasm sources:

  ```sh
  cd patches/ring
  for pl in crypto/fipsmodule/aes/asm/bsaes-armv7.pl crypto/fipsmodule/aes/asm/ghash-armv4.pl \
            crypto/fipsmodule/aes/asm/vpaes-armv7.pl crypto/fipsmodule/bn/asm/armv4-mont.pl \
            crypto/chacha/asm/chacha-armv4.pl crypto/fipsmodule/sha/asm/sha256-armv4.pl \
            crypto/fipsmodule/sha/asm/sha512-armv4.pl; do
      perl "$pl" ios32 "pregenerated/$(basename "$pl" .pl)-ios32.S"
  done
  ```

- `crypto/curve25519/asm/x25519-asm-arm.S` and `crypto/poly1305/poly1305_arm_asm.S` were ELF only.
  They now also assemble on Apple: `.private_extern` instead of `.hidden`, no `.type`, no `.fpu`
  (NEON comes from the armv7s target), and the symbols are aliased to their underscored Mach-O names,
  which is what ring's prefix header renames on Apple.

The assembly is the same BoringSSL code ring uses on 32-bit Arm Linux, assembled for Mach-O. It hasn't
been tested on a device independently of FoxMusic: a successful TLS connection to Spotify exercises it.

## dns-sd 0.1.3

`build.rs` only skips its Linux path (`pkg-config` for Avahi's `libdns_sd`) when the target name contains
"darwin", which iOS targets (`*-apple-ios`) don't. It now also skips it for "apple" targets: `dns_sd` is
part of libSystem on every Apple platform, including iOS 6.

## librespot-core 0.8.0

`src/config.rs`: `OS` is `"linux"` on iOS. Everything that identifies the client derives from that constant
(handshake platform, login packet OS, default client ID, login5, spclient platform data, user agent). As
`"ios"` (`PLATFORM_IPHONE_ARM` with Spotify's iOS client ID) every access point rejects the login with
`TryAnotherAP`, the same thing librespot already works around for Android by reporting Linux. On iOS it now
logs in as Linux ARM with librespot's usual desktop (keymaster) client ID.

`src/audio_key.rs`: the audio key response timeout is 10 seconds instead of 1.5. On an iPhone 5 the key
often arrives after about 3 seconds. When the wait times out, the player continues without decryption and
the track can't be decoded. A key that arrives too late was logged as "could not dispatch command:
... other end of channel disconnected". The pending request is now removed when it times out.
