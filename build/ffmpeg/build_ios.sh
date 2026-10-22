#!/usr/bin/env bash
# Build LAME and a minimal, audio-only, LGPL FFmpeg for iOS as shared libraries:
#   device     arm64                  (iphoneos SDK)
#   simulator  arm64 and x86_64       (iphonesimulator SDK), merged into one universal dylib
# Output: build/work/out/ios/{device,simulator}/lib/*.dylib and build/work/out/ios/include.
#
# The configure flags mirror build_macos.sh, docs/project_plan.md section 5.3 and
# .claude/skills/ffmpeg-build/configure-flags.md. Do not widen them without recording the reason.
# Run build/ffmpeg/fetch_sources.sh first. Keep a log with:
#   build/ffmpeg/build_ios.sh > build/work/build-ios.log 2>&1
# (macOS ships bash 3.2, so empty arrays are expanded with the ${arr[@]+...} form under set -u.)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
work="$root/build/work"
src="$work/src"
out="$work/out/ios"
jobs="$(sysctl -n hw.ncpu)"
build_arch="$(uname -m)"
[ "$build_arch" = "arm64" ] && build_triple="aarch64-apple-darwin" || build_triple="x86_64-apple-darwin"

# slice name | sdk | arch | clang target
slices=(
  "device-arm64|iphoneos|arm64|arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
  "sim-arm64|iphonesimulator|arm64|arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
  "sim-x86_64|iphonesimulator|x86_64|x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
)

rm -rf "$work/build-ios" "$out"
mkdir -p "$work/build-ios" "$out/device/lib" "$out/simulator/lib" "$out/include"

for entry in "${slices[@]}"; do
  IFS='|' read -r slice sdk arch target <<<"$entry"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  base="$work/build-ios/$slice"
  prefix="$base/prefix"
  mkdir -p "$prefix" "$base/lame" "$base/ffmpeg"
  cflags="-target $target -isysroot $sysroot"
  # Always differs from the build triple, so configure scripts run in cross-compile mode.
  if [ "$arch" = "arm64" ]; then host="aarch64-apple-darwin"; else host="x86_64-apple-darwin"; fi
  if [ "$host" = "$build_triple" ]; then
    [ "$arch" = "arm64" ] && fake_build="x86_64-apple-darwin" || fake_build="aarch64-apple-darwin"
  else
    fake_build="$build_triple"
  fi

  # LAME: library only (no frontend), shared. The target flags live in CC because libtool drops
  # -target and -isysroot from LDFLAGS when it links the dylib.
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$base/lame" --strip-components=1
  (
    cd "$base/lame"
    # Newer linkers reject this symbol, which LAME 3.100 lists but no longer defines.
    sed -i '' '/lame_init_old/d' include/libmp3lame.sym
    ./configure --build="$fake_build" --host="$host" --prefix="$prefix" \
      --disable-frontend --disable-static --enable-shared \
      CC="clang $cflags" CFLAGS="-O2" LDFLAGS=""
    make -j"$jobs"
    make install
  )

  # FFmpeg: start from --disable-everything and enable only the components in section 5.3.
  tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$base/ffmpeg" --strip-components=1
  asm_args=()
  [ "$arch" = "x86_64" ] && asm_args=(--disable-x86asm) # keeps nasm out of the build requirements
  (
    cd "$base/ffmpeg"
    # Decoders beyond the section 5.3 table: mp3float is the decoder FFmpeg actually uses for MP3
    # (mp3 is the fixed-point variant); pcm_u8 reads 8-bit WAV input (within the pcm_* range).
    ./configure \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=darwin --arch="$arch" \
      --cc="clang $cflags" \
      --extra-cflags="-I$prefix/include" \
      --extra-ldflags="-L$prefix/lib" \
      ${asm_args[@]+"${asm_args[@]}"} \
      --disable-everything \
      --disable-programs --disable-doc --disable-debug \
      --disable-avdevice --disable-avfilter --disable-swscale \
      --disable-network --disable-autodetect \
      --disable-static --enable-shared --enable-small \
      --enable-libmp3lame \
      --enable-protocol=file \
      --enable-demuxer=mp3,mov,asf,wav,aac \
      --enable-muxer=mp3,ipod,asf,wav,adts \
      --enable-decoder=mp3,mp3float,aac,wmav1,wmav2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8 \
      --enable-encoder=libmp3lame,aac,wmav2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le \
      --enable-parser=mpegaudio,aac
    make -j"$jobs"
    make install
  )
done

cp -R "$work/build-ios/device-arm64/prefix/include/." "$out/include/"

# Device: single arm64 slice. Simulator: arm64 + x86_64 merged. Stable @rpath install names.
for lib in libavformat libavcodec libswresample libavutil libmp3lame; do
  cp "$(readlink -f "$work/build-ios/device-arm64/prefix/lib/$lib.dylib")" "$out/device/lib/$lib.dylib"
  lipo -create \
    "$(readlink -f "$work/build-ios/sim-arm64/prefix/lib/$lib.dylib")" \
    "$(readlink -f "$work/build-ios/sim-x86_64/prefix/lib/$lib.dylib")" \
    -output "$out/simulator/lib/$lib.dylib"
done

# Point ids and inter-library references at @rpath.
for dylib in "$out"/device/lib/*.dylib "$out"/simulator/lib/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
  while read -r dep; do
    depbase="$(basename "$dep")"
    case "$depbase" in
      libavformat*|libavcodec*|libswresample*|libavutil*|libmp3lame*)
        name="${depbase%%.*}"
        install_name_tool -change "$dep" "@rpath/$name.dylib" "$dylib"
        ;;
    esac
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -v '^@rpath' | grep -v '^/usr/lib' | grep -v '^/System' || true)
done

echo "Built iOS dylibs in $out:"
ls -l "$out/device/lib" "$out/simulator/lib"
du -sh "$out/device/lib" "$out/simulator/lib"
