# Iroh native bindings

Swift bindings and licenses are copied without modification from n0-computer/iroh-ffi
v1.1.0, commit `5e451092dba0c1a09ee83ff6e5be37b1152a5c58`. The Android JNI initializer
under mobile/modules/abstract-internet has the same origin and licenses.

Run `scripts/prepare-iroh.sh apple` before generating/building the desktop project or
installing mobile pods. It verifies the upstream source/archive digests, adds Intel
Mac support, and rebuilds iOS binaries for the existing iOS 15.1 minimum. The upstream
iOS download requires 17.5, so using it directly would silently break older devices.
The generated Swift is compiled in Swift 5 mode, matching upstream.

For Android, set `ANDROID_NDK_HOME` to NDK 27 or newer and run
`scripts/prepare-iroh.sh android`. This builds the matching Rust library for all four
ABIs with 16 KB ELF alignment. The module consumes the matching Kotlin API from Maven
Central and JNA 5.18.1 (including Android 16 KB dispatch fixes). Do not replace these binaries with the upstream 1.1.0 AAR: its native
libraries predate the 16 KB fix. Local device builds may set
`IROH_ANDROID_ABIS=arm64-v8a`; CI and publishing always build all four architectures.

Artifacts are ignored, cached in CI, and never fetched at app runtime. Rust 1.93.1
and the upstream Cargo.lock pin the native builds; the preparation script is the
source of truth for checksums and build settings.
