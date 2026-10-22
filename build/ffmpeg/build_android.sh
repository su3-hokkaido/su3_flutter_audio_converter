#!/usr/bin/env bash
# Build LAME and a minimal, audio-only, LGPL FFmpeg for Android (arm64-v8a, armeabi-v7a, x86_64) as
# shared libraries with the Android NDK, and install them into android/src/main/jniLibs/<abi>/.
#
# The configure flags mirror build_macos.sh, docs/project_plan.md section 5.3 and
# .claude/skills/ffmpeg-build/configure-flags.md. Do not widen them without recording the reason.
# Run build/ffmpeg/fetch_sources.sh first. Keep a log with:
#   build/ffmpeg/build_android.sh > build/work/build-android.log 2>&1
# Headers are installed into prebuilt/include (shared with the other platforms). The binaries and
# headers are git-ignored and never committed.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
work="$root/build/work"
src="$work/src"
out="$work/out/android"
jni="$root/android/src/main/jniLibs"
abis=(arm64-v8a armeabi-v7a x86_64)

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ndk="${ANDROID_NDK_HOME:-$sdk/ndk/$ANDROID_NDK_VERSION}"
[ -d "$ndk" ] || { echo "error: NDK $ANDROID_NDK_VERSION not found at $ndk" >&2; exit 1; }
case "$(uname -s)" in
  Darwin) host_tag=darwin-x86_64; jobs="$(sysctl -n hw.ncpu)" ;;
  Linux) host_tag=linux-x86_64; jobs="$(nproc)" ;;
  *) echo "error: unsupported build host" >&2; exit 1 ;;
esac
tc="$ndk/toolchains/llvm/prebuilt/$host_tag/bin"
api="$ANDROID_API_LEVEL"

# 16 KB page-size compatible linking (Android 15+), applied to every ABI.
ldflags_common="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

rm -rf "$work/build-android" "$out"
mkdir -p "$work/build-android" "$out"

for abi in "${abis[@]}"; do
  case "$abi" in
    arm64-v8a)   triple=aarch64-linux-android;   clang_triple="aarch64-linux-android$api";   ff_arch=aarch64; ff_extra=(--cpu=armv8-a) ;;
    armeabi-v7a) triple=arm-linux-androideabi;   clang_triple="armv7a-linux-androideabi$api"; ff_arch=arm;     ff_extra=(--cpu=armv7-a) ;;
    x86_64)      triple=x86_64-linux-android;    clang_triple="x86_64-linux-android$api";    ff_arch=x86_64;  ff_extra=(--disable-x86asm) ;; # keeps nasm out of the requirements
  esac
  cc="$tc/${clang_triple}-clang"
  build="$work/build-android/$abi"
  prefix="$build/prefix"
  mkdir -p "$prefix" "$build/lame" "$build/ffmpeg"

  # LAME: library only (no frontend), shared, no version suffix on the SONAME (-avoid-version).
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$build/lame" --strip-components=1
  (
    cd "$build/lame"
    # LAME 3.100 lists this symbol in its export list but no longer defines it.
    sed '/lame_init_old/d' include/libmp3lame.sym > include/libmp3lame.sym.new
    mv include/libmp3lame.sym.new include/libmp3lame.sym
    ./configure --host="$triple" --prefix="$prefix" \
      --disable-frontend --disable-static --enable-shared \
      CC="$cc" AR="$tc/llvm-ar" RANLIB="$tc/llvm-ranlib" STRIP="$tc/llvm-strip" \
      CFLAGS="-O2 -fPIC" LDFLAGS="$ldflags_common"
    # -avoid-version is a libtool flag, so it is passed at link time rather than to configure.
    make -j"$jobs" LDFLAGS="$ldflags_common -avoid-version"
    make install LDFLAGS="$ldflags_common -avoid-version"
  )

  # FFmpeg: start from --disable-everything and enable only the components in section 5.3.
  tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$build/ffmpeg" --strip-components=1
  (
    cd "$build/ffmpeg"
    # Decoders beyond the section 5.3 table: mp3float is the decoder FFmpeg actually uses for MP3
    # (mp3 is the fixed-point variant); pcm_u8 reads 8-bit WAV input (within the pcm_* range).
    ./configure \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=android --arch="$ff_arch" \
      ${ff_extra[@]+"${ff_extra[@]}"} \
      --cc="$cc" --ar="$tc/llvm-ar" --ranlib="$tc/llvm-ranlib" \
      --nm="$tc/llvm-nm" --strip="$tc/llvm-strip" \
      --extra-cflags="-I$prefix/include -fPIC" \
      --extra-ldflags="-L$prefix/lib $ldflags_common" \
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
    # Android does not load versioned library names (libavcodec.so.62): drop the version suffix so
    # the SONAME is plain libavcodec.so and Gradle packages the files.
    sed -i.bak \
      -e 's|^SLIBNAME_WITH_VERSION=.*|SLIBNAME_WITH_VERSION=$(SLIBNAME)|' \
      -e 's|^SLIBNAME_WITH_MAJOR=.*|SLIBNAME_WITH_MAJOR=$(SLIBNAME)|' \
      -e 's|^LIB_INSTALL_EXTRA_CMD=.*|LIB_INSTALL_EXTRA_CMD=|' \
      -e 's|^SLIB_INSTALL_LINKS=.*|SLIB_INSTALL_LINKS=|' \
      ffbuild/config.mak
    # A newer FFmpeg may rename these variables, which would silently leave versioned SONAMEs.
    grep -q '^SLIBNAME_WITH_MAJOR=\$(SLIBNAME)$' ffbuild/config.mak \
      || { echo "error: config.mak patch did not apply (FFmpeg changed?)" >&2; exit 1; }
    make -j"$jobs"
    make install
  )

  mkdir -p "$out/$abi" "$jni/$abi"
  for lib in libavformat libavcodec libswresample libavutil libmp3lame; do
    cp "$prefix/lib/$lib.so" "$out/$abi/$lib.so"
    "$tc/llvm-strip" --strip-unneeded "$out/$abi/$lib.so"
    cp "$out/$abi/$lib.so" "$jni/$abi/$lib.so"
  done
done

# Headers for compiling src/ (identical across ABIs for the APIs the wrapper uses).
mkdir -p "$root/prebuilt/include"
cp -R "$work/build-android/${abis[0]}/prefix/include/." "$root/prebuilt/include/"

echo "Sizes per ABI (stripped):"
for abi in "${abis[@]}"; do
  echo "== $abi"
  ls -l "$jni/$abi"
  du -sk "$jni/$abi" | awk '{print $1 " KiB total"}'
  for so in "$jni/$abi"/*.so; do
    echo "  $(basename "$so"): SONAME=$("$tc/llvm-readelf" -d "$so" | grep SONAME | sed 's/.*\[\(.*\)\]/\1/')"
  done
done
