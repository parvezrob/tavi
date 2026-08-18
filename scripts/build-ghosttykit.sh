#!/bin/bash

set -euo pipefail

readonly ZIG_VERSION="0.15.2"
readonly ZIG_ARCHIVE="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
readonly ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
readonly ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_ARCHIVE}"
readonly GHOSTTY_REPOSITORY="https://github.com/wiedymi/ghostty.git"
readonly GHOSTTY_REVISION="91fe505e60bbe72ff08c881d2882acad6a56cb9f"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_root="${MOCHA_GHOSTTY_BUILD_ROOT:-$repo_root/.build/ghosttykit}"
downloads_dir="$build_root/downloads"
toolchains_dir="$build_root/toolchains"
sources_dir="$build_root/sources"
zig_dir="$toolchains_dir/zig-aarch64-macos-${ZIG_VERSION}"
zig_archive_path="$downloads_dir/$ZIG_ARCHIVE"
ghostty_dir="$sources_dir/ghostty-$GHOSTTY_REVISION"
zig_patch="$script_dir/patches/zig-0.15.2-macos26-sdk-overlay.patch"
ghostty_patch="$script_dir/patches/ghostty-custom-io-91fe505-mocha.patch"
xcode_developer_dir="${MOCHA_XCODE_DEVELOPER_DIR:-$(xcode-select -p)}"

require_command curl
require_command git
require_command patch
require_command plutil
require_command shasum
require_command tar
require_command xcrun

[ "$(uname -m)" = "arm64" ] || fail "the pinned Zig toolchain currently supports Apple Silicon hosts only"
[ -d "$xcode_developer_dir" ] || fail "Xcode developer directory not found: $xcode_developer_dir"
[ -f "$zig_patch" ] || fail "missing Zig patch: $zig_patch"
[ -f "$ghostty_patch" ] || fail "missing Ghostty patch: $ghostty_patch"

mkdir -p "$downloads_dir" "$toolchains_dir" "$sources_dir"

if [ ! -f "$zig_archive_path" ]; then
  echo "Downloading Zig $ZIG_VERSION"
  curl --fail --location --retry 3 --retry-all-errors --output "$zig_archive_path.partial" "$ZIG_URL"
  mv "$zig_archive_path.partial" "$zig_archive_path"
fi

actual_zig_sha="$(shasum -a 256 "$zig_archive_path" | awk '{print $1}')"
[ "$actual_zig_sha" = "$ZIG_SHA256" ] || fail "Zig archive checksum mismatch"

if [ ! -x "$zig_dir/zig" ]; then
  [ ! -e "$zig_dir" ] || fail "incomplete Zig toolchain exists at $zig_dir"
  echo "Extracting Zig $ZIG_VERSION"
  tar -xf "$zig_archive_path" -C "$toolchains_dir"
fi

if ! grep -q "MOCHA_SDK_OVERLAY_ROOT" "$zig_dir/lib/std/zig/system/darwin.zig"; then
  echo "Patching Zig SDK discovery"
  patch -d "$zig_dir" -p1 < "$zig_patch"
fi
grep -q "MOCHA_SDK_OVERLAY_ROOT" "$zig_dir/lib/std/zig/system/darwin.zig" || fail "Zig SDK patch verification failed"

if [ ! -d "$ghostty_dir/.git" ]; then
  [ ! -e "$ghostty_dir" ] || fail "incomplete Ghostty checkout exists at $ghostty_dir"
  echo "Cloning pinned Ghostty custom-I/O fork"
  git clone --filter=blob:none --no-checkout "$GHOSTTY_REPOSITORY" "$ghostty_dir"
  git -C "$ghostty_dir" fetch --depth 1 origin "$GHOSTTY_REVISION"
  git -C "$ghostty_dir" checkout --detach "$GHOSTTY_REVISION"
fi

actual_revision="$(git -C "$ghostty_dir" rev-parse HEAD)"
[ "$actual_revision" = "$GHOSTTY_REVISION" ] || fail "Ghostty checkout is at $actual_revision, expected $GHOSTTY_REVISION"

ghostty_patch_marker="$ghostty_dir/.git/mocha-patch.sha256"
expected_patch_sha="$(shasum -a 256 "$ghostty_patch" | awk '{print $1}')"
expected_patch_files="$(sed -n 's|^diff --git a/\([^ ]*\).*|\1|p' "$ghostty_patch")"

if [ -f "$ghostty_patch_marker" ]; then
  recorded_patch_sha="$(tr -d '\n' < "$ghostty_patch_marker")"
  [ "$recorded_patch_sha" = "$expected_patch_sha" ] || fail "Ghostty patch set changed; remove $ghostty_dir and rebuild"
fi

actual_patch_files="$(git -C "$ghostty_dir" diff --name-only)"
if [ -z "$actual_patch_files" ]; then
  echo "Applying Mocha Ghostty patches"
  git -C "$ghostty_dir" apply --unidiff-zero "$ghostty_patch"
fi

actual_patch_files="$(git -C "$ghostty_dir" diff --name-only)"
[ "$actual_patch_files" = "$expected_patch_files" ] || fail "Ghostty checkout contains unexpected tracked changes"
actual_patch_sha="$(git -C "$ghostty_dir" diff -U0 | shasum -a 256 | awk '{print $1}')"
[ "$actual_patch_sha" = "$expected_patch_sha" ] || fail "Ghostty checkout does not exactly match the Mocha patch set"
printf '%s\n' "$expected_patch_sha" > "$ghostty_patch_marker"
git -C "$ghostty_dir" diff --check

macos_sdk="$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk macosx --show-sdk-path)"
iphoneos_sdk="$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk iphoneos --show-sdk-path)"
simulator_sdk="$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk iphonesimulator --show-sdk-path)"
sdk_signature="$(basename "$macos_sdk")-$(basename "$iphoneos_sdk")-$(basename "$simulator_sdk")"
overlay_root="$build_root/sdk-overlays/$sdk_signature"

mirror_sdk() {
  local sdk_name="$1"
  local real_sdk="$2"
  local overlay="$overlay_root/$sdk_name"
  local entry
  local name

  mkdir -p "$overlay/usr/lib"
  for entry in "$real_sdk"/*; do
    name="${entry##*/}"
    [ "$name" = "usr" ] || ln -s "$entry" "$overlay/$name"
  done
  for entry in "$real_sdk/usr"/*; do
    name="${entry##*/}"
    [ "$name" = "lib" ] || ln -s "$entry" "$overlay/usr/$name"
  done
  for entry in "$real_sdk/usr/lib"/*; do
    name="${entry##*/}"
    case "$name" in
      libSystem.tbd|libSystem.B.tbd) ;;
      *) ln -s "$entry" "$overlay/usr/lib/$name" ;;
    esac
  done
  cp "$zig_dir/lib/libc/darwin/libSystem.tbd" "$overlay/usr/lib/libSystem.tbd"
  cp "$zig_dir/lib/libc/darwin/libSystem.tbd" "$overlay/usr/lib/libSystem.B.tbd"
}

if [ ! -f "$overlay_root/.mocha-ready" ]; then
  [ ! -e "$overlay_root" ] || fail "incomplete SDK overlay exists at $overlay_root"
  echo "Creating Apple SDK overlays"
  mirror_sdk macosx "$macos_sdk"
  mirror_sdk iphoneos "$iphoneos_sdk"
  mirror_sdk iphonesimulator "$simulator_sdk"
  touch "$overlay_root/.mocha-ready"
fi

if ! DEVELOPER_DIR="$xcode_developer_dir" xcrun -sdk iphoneos metal --version >/dev/null 2>&1; then
  fail "Metal Toolchain is missing; install it with: xcodebuild -downloadComponent MetalToolchain"
fi

echo "Building GhosttyKit at $GHOSTTY_REVISION"
(
  cd "$ghostty_dir"
  MOCHA_XCODE_DEVELOPER_DIR="$xcode_developer_dir" \
  MOCHA_SDK_OVERLAY_ROOT="$overlay_root" \
  DEVELOPER_DIR=/nonexistent \
  PATH="$zig_dir:$PATH" \
    "$zig_dir/zig" build \
      -Demit-xcframework=true \
      -Demit-macos-app=false \
      -Doptimize=ReleaseFast
)

framework_path="$ghostty_dir/macos/GhosttyKit.xcframework"
framework_plist="$framework_path/Info.plist"
[ -f "$framework_plist" ] || fail "GhosttyKit XCFramework was not produced"

for identifier in ios-arm64 ios-arm64-simulator macos-arm64_x86_64; do
  plutil -p "$framework_plist" | grep -q "$identifier" || fail "missing XCFramework slice: $identifier"
done
grep -q "ghostty_surface_feed_data" "$framework_path/ios-arm64/Headers/ghostty.h" || fail "custom input API is missing"
grep -q "ghostty_surface_set_write_callback" "$framework_path/ios-arm64/Headers/ghostty.h" || fail "custom output API is missing"

frameworks_dir="$repo_root/apps/ios/Frameworks"
framework_link="$frameworks_dir/GhosttyKit.xcframework"
mkdir -p "$frameworks_dir"
if [ -L "$framework_link" ]; then
  [ "$(readlink "$framework_link")" = "$framework_path" ] || fail "unexpected GhosttyKit symlink at $framework_link"
elif [ -e "$framework_link" ]; then
  fail "refusing to replace existing path: $framework_link"
else
  ln -s "$framework_path" "$framework_link"
fi

echo "GhosttyKit ready: $framework_link"
