#!/usr/bin/env bash
# Reproducible native artifacts. apple: universal Mac + iOS 15.1; android: 16 KB pages.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
mode=${1:-apple}
cache="$root/build/iroh-1.1.0"
if test "$mode" = apple && test -f Packages/Iroh/Iroh.xcframework/.abstract-native-v1; then exit 0; fi
if test "$mode" = android && test -f mobile/modules/abstract-internet/android/src/main/jniLibs/.abstract-native-v1; then exit 0; fi
mkdir -p "$cache"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}
toolchain=1.93.1
source_sha=4bfd008f6aa247a5b156ddc0cc682793c7dd107e11620d3e1bd9e60dd633ddcd

download() {
  local url=$1 destination=$2 checksum=$3
  if ! test -f "$destination"; then curl -fL --retry 3 "$url" -o "$destination"; fi
  echo "$checksum  $destination" | shasum -a 256 -c -
}
download https://api.github.com/repos/n0-computer/iroh-ffi/tarball/v1.1.0 "$cache/source.tar.gz" "$source_sha"
if ! test -f "$cache/source/Cargo.toml"; then
  mkdir -p "$cache/source"
  tar -xzf "$cache/source.tar.gz" --strip-components=1 -C "$cache/source"
fi
rustup toolchain install "$toolchain" --profile minimal
build() { cargo +"$toolchain" build --manifest-path "$cache/source/Cargo.toml" --locked --release --lib --target "$1"; }

case "$mode" in
  apple)
    test "$(uname -s)" = Darwin
    download https://github.com/n0-computer/iroh-ffi/releases/download/v1.1.0/IrohLib.xcframework.zip \
      "$cache/apple.zip" ad46dadf09f9224157512992923562931ed60f252414230d50893a4d515c5776
    if ! test -d "$cache/upstream"; then unzip -q "$cache/apple.zip" -d "$cache/upstream"; fi
    if test -f Packages/Iroh/Iroh.xcframework/.abstract-native-v1; then exit 0; fi
    export MACOSX_DEPLOYMENT_TARGET=15.0 IPHONEOS_DEPLOYMENT_TARGET=15.1
    rustup target add --toolchain "$toolchain" x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
    for target in x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do build "$target"; done
    binaries="$cache/source/target"
    headers="$cache/upstream/Iroh.xcframework/macos-arm64/Headers"
    mkdir -p "$cache/mac" "$cache/simulator"
    lipo -create "$cache/upstream/Iroh.xcframework/macos-arm64/libiroh_ffi.a" \
      "$binaries/x86_64-apple-darwin/release/libiroh_ffi.a" -output "$cache/mac/libiroh_ffi.a"
    lipo -create "$binaries/aarch64-apple-ios-sim/release/libiroh_ffi.a" \
      "$binaries/x86_64-apple-ios/release/libiroh_ffi.a" -output "$cache/simulator/libiroh_ffi.a"
    rm -rf "$cache/complete.xcframework"
    xcodebuild -create-xcframework -library "$cache/mac/libiroh_ffi.a" -headers "$headers" \
      -library "$cache/simulator/libiroh_ffi.a" -headers "$headers" \
      -library "$binaries/aarch64-apple-ios/release/libiroh_ffi.a" -headers "$headers" \
      -output "$cache/complete.xcframework"
    rm -rf Packages/Iroh/Iroh.xcframework
    mv "$cache/complete.xcframework" Packages/Iroh/Iroh.xcframework
    touch Packages/Iroh/Iroh.xcframework/.abstract-native-v1
    ;;
  android)
    : "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 27 or newer}"
    case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 1 ;; esac
    llvm="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
    export RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
    output="$root/mobile/modules/abstract-internet/android/src/main/jniLibs"
    # Set IROH_ANDROID_ABIS=arm64-v8a for a local device build. CI builds all ABIs.
    for abi in ${IROH_ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64 x86}; do
      case "$abi" in
        arm64-v8a) target=aarch64-linux-android; cc=aarch64-linux-android24-clang ;;
        armeabi-v7a) target=armv7-linux-androideabi; cc=armv7a-linux-androideabi24-clang ;;
        x86_64) target=x86_64-linux-android; cc=x86_64-linux-android24-clang ;;
        x86) target=i686-linux-android; cc=i686-linux-android24-clang ;;
        *) echo "Unknown ABI: $abi" >&2; exit 1 ;;
      esac
      rustup target add --toolchain "$toolchain" "$target"
      cargo_key=$(echo "$target" | tr '[:lower:]-' '[:upper:]_')
      cc_key=${target//-/_}
      env "CARGO_TARGET_${cargo_key}_LINKER=$llvm/$cc" "CC_${cc_key}=$llvm/$cc" "AR_${cc_key}=$llvm/llvm-ar" \
        cargo +"$toolchain" build --manifest-path "$cache/source/Cargo.toml" --locked --release --lib --target "$target"
      mkdir -p "$output/$abi"
      cp "$cache/source/target/$target/release/libiroh_ffi.so" "$output/$abi/"
      # Fail if any LOAD segment is not aligned for Android's 16 KB pages.
      "$llvm/llvm-readelf" -lW "$output/$abi/libiroh_ffi.so" | awk '/ LOAD / { if ($NF != "0x4000") exit 1; found=1 } END { if (!found) exit 1 }'
    done
    if test -z "${IROH_ANDROID_ABIS:-}"; then touch "$output/.abstract-native-v1"; fi
    ;;
  *) echo 'Usage: scripts/prepare-iroh.sh apple|android' >&2; exit 1 ;;
esac
