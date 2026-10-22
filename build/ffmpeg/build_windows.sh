#!/usr/bin/env bash
# Build LAME and a minimal, audio-only, LGPL FFmpeg for Windows x64 as shared libraries (DLLs with
# MSVC import libraries) under build/work/out/windows, and stage them in prebuilt/windows.
#
# STATUS: UNVERIFIED. Written on macOS without any ability to run it. The first run on Windows is
# expected to need small fixes; record them in docs/2026-10-22_04_m4-windows/design.md.
#
# Toolchain choice: MSVC (cl.exe / link.exe) driven from MSYS2 with FFmpeg --toolchain=msvc, not
# MSYS2 MinGW-w64.
#   - Flutter's Windows runner and the plugin wrapper (windows/CMakeLists.txt) are built with MSVC and
#     /MD (the shared UCRT). The FFmpeg and LAME DLLs then use the same C runtime, and FFmpeg's
#     MSVC toolchain emits the import libraries (avcodec.lib, ...) that the MSVC linker needs.
#     MinGW would need extra import-library generation (lib.exe /DEF) and links a different runtime
#     setup; its DLLs also tend to depend on libgcc / libwinpthread DLLs that would have to be
#     bundled too.
#   - Both choices keep FFmpeg and LAME as separate shared DLLs, which is the LGPL relinking
#     requirement (docs/project_plan.md section 5.4).
#   - LAME 3.100 has no usable autoconf path for MSVC, so it is compiled directly with cl.exe
#     (see build_lame below). Its sources are the unmodified release tarball.
#
# Prerequisites (all on the machine that runs this script):
#   1. Visual Studio 2022 (or Build Tools) with the "Desktop development with C++" workload.
#   2. MSYS2 (https://www.msys2.org/). In an MSYS2 (not MinGW) shell install:
#        pacman -S --needed make diffutils tar xz curl nasm pkgconf
#      nasm enables FFmpeg's x86-64 assembly. If nasm is not installed the script falls back to
#      --disable-x86asm (slower decoding and encoding but the same output formats).
#   3. Start MSYS2 from an x64 MSVC environment so cl.exe, link.exe, lib.exe are on PATH, with the
#      MSYS2 PATH appended and MSYS2's own /usr/bin/link.exe hidden by the MSVC one. From a
#      "x64 Native Tools Command Prompt for VS 2022":
#        set MSYS2_PATH_TYPE=inherit
#        C:\msys64\msys2_shell.cmd -msys2 -use-full-path -here
#      Then, inside the shell opened in the repository root:
#        build/ffmpeg/build_windows.sh > build/work/build-windows.log 2>&1
#
# The configure flags mirror docs/project_plan.md section 5.3 and
# .claude/skills/ffmpeg-build/configure-flags.md (same list as build_macos.sh). Do not widen them
# without recording the reason. Only x64 is built (docs/project_plan.md section 6.3).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
work="$root/build/work"
src="$work/src"
bld="$work/build-windows"
out="$work/out/windows"
dest="$root/prebuilt/windows"
jobs="$(nproc)"

# --- Environment checks -------------------------------------------------------------------------

case "$(uname -s)" in
  MSYS*|MINGW*) ;;
  *) echo "error: run this script inside MSYS2 on Windows" >&2; exit 1 ;;
esac
command -v cl >/dev/null || { echo "error: cl.exe not found; start MSYS2 from an x64 MSVC prompt (see header)" >&2; exit 1; }
link_path="$(command -v link || true)"
if [ -z "$link_path" ] || [ "$link_path" = "/usr/bin/link" ]; then
  echo "error: link resolves to $link_path (MSYS2 coreutils); the MSVC link.exe must come first on PATH" >&2
  exit 1
fi
command -v lib >/dev/null || { echo "error: lib.exe not found on PATH" >&2; exit 1; }
for tool in make tar curl sha256sum cygpath; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (pacman -S make tar curl diffutils)" >&2; exit 1; }
done
# The MSVC compiler must target x64.
case "$(cl 2>&1 | head -n 1)" in
  *x64*) ;;
  *) echo "error: cl.exe is not the x64 compiler (use the x64 Native Tools prompt)" >&2; exit 1 ;;
esac

# --- Sources (checksum verified before use) -----------------------------------------------------
# fetch_sources.sh needs shasum, which MSYS2 does not provide by default, so the same verification
# is done here with sha256sum. The tarballs are shared with the other platforms in build/work/src.

mkdir -p "$src"
fetch() {
  local name="$1" url="$2" expected="$3"
  local file="$src/$(basename "$url")"
  [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$url"
  local actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ -z "$expected" ]; then
    echo "error: ${name}_SHA256 is empty in build/versions.env (actual: $actual)" >&2
    exit 1
  elif [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch for $file (expected $expected, actual $actual)" >&2
    exit 1
  fi
  echo "ok: $file"
}
fetch FFMPEG "$FFMPEG_URL" "$FFMPEG_SHA256"
fetch LAME "$LAME_URL" "$LAME_SHA256"

rm -rf "$bld" "$out"
prefix="$bld/prefix"
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/include/lame" "$bld/lame" "$bld/ffmpeg" "$out"
# Windows-style (C:/...) spellings of the prefix for compiler and linker flags.
prefix_w="$(cygpath -m "$prefix")"

# --- LAME: library only, shared, compiled directly with cl.exe ----------------------------------
# Sources follow libmp3lame/Makefile.am and mpglib/Makefile.am of LAME 3.100. HAVE_XMMINTRIN_H is
# left undefined, so the optional SSE quantizer (vector/xmm_quantize_sub.c) is not used. HAVE_MPGLIB
# is needed because include/lame.def exports the hip_* / lame_decode* functions. The export list is
# include/lame.def (it does not contain the lame_init_old symbol that breaks other linkers).
# Output: libmp3lame.dll plus the import library mp3lame.lib (FFmpeg's MSVC toolchain turns
# -lmp3lame into mp3lame.lib).
build_lame() {
  tar -xzf "$src/lame-$LAME_VERSION.tar.gz" -C "$bld/lame" --strip-components=1
  (
    cd "$bld/lame"
    mkdir -p obj gen
    cp configMS.h gen/config.h
    local sources=(
      libmp3lame/VbrTag.c libmp3lame/bitstream.c libmp3lame/encoder.c libmp3lame/fft.c
      libmp3lame/gain_analysis.c libmp3lame/id3tag.c libmp3lame/lame.c
      libmp3lame/mpglib_interface.c libmp3lame/newmdct.c libmp3lame/presets.c
      libmp3lame/psymodel.c libmp3lame/quantize.c libmp3lame/quantize_pvt.c
      libmp3lame/reservoir.c libmp3lame/set_get.c libmp3lame/tables.c libmp3lame/takehiro.c
      libmp3lame/util.c libmp3lame/vbrquantize.c libmp3lame/version.c
      mpglib/common.c mpglib/dct64_i386.c mpglib/decode_i386.c mpglib/interface.c
      mpglib/layer1.c mpglib/layer2.c mpglib/layer3.c mpglib/tabinit.c
    )
    local here_w
    here_w="$(cygpath -m "$PWD")"
    # Dash-style options keep MSYS2 from rewriting them as POSIX paths. /MD matches Flutter.
    cl -nologo -O2 -MD -DNDEBUG -DWIN32 -D_CRT_SECURE_NO_WARNINGS -DHAVE_CONFIG_H -DHAVE_MPGLIB \
      -DSTDC_HEADERS -Dlame_EXPORTS \
      -I"$here_w/gen" -I"$here_w" -I"$here_w/include" -I"$here_w/libmp3lame" -I"$here_w/mpglib" \
      -Fo"$here_w/obj/" -c "${sources[@]}"
    link -nologo -DLL -OUT:"$here_w/libmp3lame.dll" -IMPLIB:"$here_w/mp3lame.lib" \
      -DEF:"$here_w/include/lame.def" obj/*.obj
    cp libmp3lame.dll "$prefix/bin/"
    cp mp3lame.lib "$prefix/lib/"
    cp include/lame.h "$prefix/include/lame/"
  )
}
build_lame

# --- FFmpeg: start from --disable-everything and enable only the components in section 5.3 -------

tar -xJf "$src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$bld/ffmpeg" --strip-components=1
asm_args=()
if ! command -v nasm >/dev/null; then
  echo "notice: nasm not found, building FFmpeg with --disable-x86asm" >&2
  asm_args=(--disable-x86asm)
fi
(
  cd "$bld/ffmpeg"
  # Decoders beyond the section 5.3 table: mp3float is the decoder FFmpeg actually uses for MP3
  # (mp3 is the fixed-point variant); pcm_u8 reads 8-bit WAV input (within the pcm_* range).
  ./configure \
    --toolchain=msvc \
    --target-os=win64 --arch=x86_64 \
    --prefix="$prefix" \
    --extra-cflags="-I$prefix_w/include" \
    --extra-ldflags="-LIBPATH:$prefix_w/lib" \
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

# --- Collect the outputs ------------------------------------------------------------------------
# bin/  runtime DLLs (avutil-*.dll, swresample-*.dll, avcodec-*.dll, avformat-*.dll, libmp3lame.dll)
# lib/  import libraries (avutil.lib, ..., mp3lame.lib)
# include/  headers used to compile src/ (kept apart from prebuilt/include, which other platforms
#           populate)
mkdir -p "$out/bin" "$out/lib" "$out/include"
cp "$prefix"/bin/*.dll "$out/bin/"
for name in avutil swresample avcodec avformat mp3lame; do
  [ -f "$prefix/lib/$name.lib" ] || { echo "error: missing import library $name.lib" >&2; exit 1; }
  cp "$prefix/lib/$name.lib" "$out/lib/"
done
cp -R "$prefix/include/." "$out/include/"

# Dependency sanity check: the DLLs must not import anything but system libraries and each other.
if command -v dumpbin >/dev/null; then
  for dll in "$out"/bin/*.dll; do
    echo "== imports of $(basename "$dll")"
    dumpbin -nologo -dependents "$(cygpath -w "$dll")" | grep -i '\.dll' || true
  done
fi

rm -rf "$dest"
mkdir -p "$dest"
cp -R "$out/bin" "$out/lib" "$out/include" "$dest/"

echo "Built DLLs in $out/bin (staged in $dest):"
ls -l "$out/bin"
echo "Size per DLL (section 6.4, x64):"
du -k "$out"/bin/*.dll
du -sh "$out/bin"
