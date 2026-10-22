#!/usr/bin/env bash
# Build LAME and a minimal, audio-only, LGPL FFmpeg for macOS (arm64 and x86_64) as shared libraries
# and merge them into universal dylibs under build/work/out/macos.
#
# The configure flags mirror docs/project_plan.md section 5.3 and
# .claude/skills/ffmpeg-build/configure-flags.md. Do not widen them without recording the reason.
# Run build/ffmpeg/fetch_sources.sh first.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
work="$root/build/work"
src="$work/src"
out="$work/out/macos"
archs=(arm64 x86_64)
jobs="$(sysctl -n hw.ncpu)"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"

rm -rf "$work/build-macos" "$out"
mkdir -p "$work/build-macos" "$out/lib" "$out/include"

for arch in "${archs[@]}"; do
  prefix="$work/build-macos/$arch/prefix"
  mkdir -p "$prefix" "$work/build-macos/$arch/lame" "$work/build-macos/$arch/ffmpeg"
  cflags="-arch $arch -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
  host_args=()
  [ "$arch" = "arm64" ] && host_args=(--host=aarch64-apple-darwin) || host_args=(--host=x86_64-apple-darwin)

  # LAME: library only (no frontend), shared.
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$work/build-macos/$arch/lame" --strip-components=1
  (
    cd "$work/build-macos/$arch/lame"
    # Newer linkers reject this symbol, which LAME 3.100 lists but no longer defines.
    sed -i '' '/lame_init_old/d' include/libmp3lame.sym
    ./configure "${host_args[@]}" --prefix="$prefix" \
      --disable-frontend --disable-static --enable-shared \
      CC="clang" CFLAGS="$cflags -O2" LDFLAGS="$cflags"
    make -j"$jobs"
    make install
  )

  # FFmpeg: start from --disable-everything and enable only the components in section 5.3.
  tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$work/build-macos/$arch/ffmpeg" --strip-components=1
  asm_args=()
  [ "$arch" = "x86_64" ] && asm_args=(--disable-x86asm) # keeps nasm out of the build requirements
  (
    cd "$work/build-macos/$arch/ffmpeg"
    ./configure \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=darwin --arch="$arch" \
      --cc="clang -arch $arch" \
      --extra-cflags="$cflags -I$prefix/include" \
      --extra-ldflags="$cflags -L$prefix/lib" \
      "${asm_args[@]}" \
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

# Merge the per-architecture dylibs into universal binaries with a stable @rpath install name.
first="${archs[0]}"
cp -R "$work/build-macos/$first/prefix/include/." "$out/include/"
for lib in libavformat libavcodec libswresample libavutil libmp3lame; do
  files=()
  for arch in "${archs[@]}"; do
    files+=("$(readlink -f "$work/build-macos/$arch/prefix/lib/$lib.dylib")")
  done
  lipo -create "${files[@]}" -output "$out/lib/$lib.dylib"
  install_name_tool -id "@rpath/$lib.dylib" "$out/lib/$lib.dylib"
done

# Point inter-library references at @rpath as well.
for dylib in "$out"/lib/*.dylib; do
  while read -r dep; do
    base="$(basename "$dep")"
    case "$base" in
      libavformat*|libavcodec*|libswresample*|libavutil*|libmp3lame*)
        name="${base%%.*}"
        install_name_tool -change "$dep" "@rpath/$name.dylib" "$dylib"
        ;;
    esac
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -v '^@rpath' | grep -v '^/usr/lib' | grep -v '^/System' || true)
done

echo "Built universal dylibs in $out/lib:"
ls -l "$out/lib"
du -sh "$out/lib"
