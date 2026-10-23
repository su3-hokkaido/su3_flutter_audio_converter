# M4 Windows: FFmpeg/LAME build and plugin integration

STATUS: UNVERIFIED. Everything here was written on macOS. Nothing was built, compiled or run for
Windows. Expect small fixes on the first run; record them in this file.

## Scope

`docs/project_plan.md` §7 Step 1 milestone 4, Windows part: build LAME 3.100 and FFmpeg 8.1.3
(same `--disable-everything` component list as `build/ffmpeg/build_macos.sh`) as x64 shared
libraries, and integrate them into the plugin through `windows/CMakeLists.txt`.

Files:

- `build/ffmpeg/build_windows.sh` - build (runs in MSYS2 with the MSVC toolchain).
- `windows/CMakeLists.txt` - compiles `src/` into `su3_flutter_audio_converter.dll`, links the import
  libraries, lists the DLLs in `su3_flutter_audio_converter_bundled_libraries`.
- Output layout (git-ignored through `/prebuilt/`): `prebuilt/windows/{bin,lib,include}`.

## Decisions

### MSVC toolchain, not MSYS2 MinGW-w64

- Flutter's Windows runner and the wrapper are built by MSVC with `/MD`. FFmpeg `--toolchain=msvc`
  uses the same runtime and emits import libraries (`avcodec.lib` ...) directly. MinGW would need
  extra `lib.exe /DEF` steps and tends to pull `libgcc` / `libwinpthread` DLLs that would also have
  to be bundled and listed for LGPL purposes.
- FFmpeg and LAME stay separate shared DLLs (LGPL relinking, §5.4) in both options.
- The cost: LAME has no working autoconf path for MSVC and its `Makefile.MSVC` targets 32-bit x86.
  `build_windows.sh` therefore compiles the unmodified LAME 3.100 sources directly with `cl.exe`
  (source list copied from `libmp3lame/Makefile.am` and `mpglib/Makefile.am`), exports through the
  shipped `include/lame.def`, and produces `libmp3lame.dll` and `mp3lame.lib`.
- LAME is built with its SSE quantizer: `configMS.h` defines `HAVE_XMMINTRIN_H` on x64, so
  `libmp3lame/vector/xmm_quantize_sub.c` is compiled in (intrinsics only, no NASM).

### Assembly

`nasm` is used for FFmpeg's x86-64 assembly when it is on PATH (one `pacman` package). If it is not,
the script prints a notice and passes `--disable-x86asm`.

### Source verification

`fetch_sources.sh` uses `shasum`, which MSYS2 does not ship, and must not be edited in this task.
`build_windows.sh` repeats the same download and SHA-256 check (with `sha256sum`) against
`build/versions.env`, using the same `build/work/src` cache.

### C wrapper review (`src/su3_flutter_audio_converter.c`)

Read for MSVC compatibility; no change made. Compound literals, designated/zero initializers,
mixed declarations, `snprintf`, `for (int ...)` are fine in MSVC C mode (VS 2019+, default C89/C99
subset used by Flutter's toolchain). There are no VLAs, no `ssize_t`, and `realpath` / `PATH_MAX` are
inside `#if !_WIN32`. Windows branches use `CreateThread`, `INIT_ONCE` + `CRITICAL_SECTION`,
`WaitForSingleObject`/`CloseHandle` and `_wremove`; they look correct on reading. Known limitation
(already documented in the source): the same-file check on Windows is a plain `strcmp`.

## Windows checklist (run on a Windows 10/11 x64 machine)

1. Install Visual Studio 2022 (or Build Tools) with "Desktop development with C++", Flutter with
   Windows desktop enabled, and MSYS2 (default path `C:\msys64`).
2. In an MSYS2 MSYS shell: `pacman -S --needed make diffutils tar xz curl nasm pkgconf`.
3. Open "x64 Native Tools Command Prompt for VS 2022" and run (in the repository root):

   ```
   set MSYS2_PATH_TYPE=inherit
   C:\msys64\msys2_shell.cmd -msys2 -use-full-path -here
   ```

4. In the MSYS2 shell that opens:

   ```
   mkdir -p build/work
   build/ffmpeg/build_windows.sh > build/work/build-windows.log 2>&1
   tail -n 30 build/work/build-windows.log
   ```

   The script stages `prebuilt/windows/{bin,lib,include}` itself and prints the size per DLL
   (report these for §6.4).
5. In a normal PowerShell, from the repository root:

   ```
   cd example
   flutter pub get
   flutter test integration_test/matrix_test.dart -d windows
   flutter test integration_test/convert_test.dart -d windows
   ```

   Run one file at a time. Check `example\build\windows\x64\runner\Debug\` for
   `su3_flutter_audio_converter.dll` plus the five FFmpeg/LAME DLLs next to the `.exe`.

Expected to need attention:

- `link.exe` resolving to MSYS2's `/usr/bin/link` (script aborts with a message if so).
- FFmpeg configure not finding LAME: it looks for `lame/lame.h` and `mp3lame.lib`
  (`config.log` in `build/work/build-windows/ffmpeg/`). The `--prefix` is passed in MSYS (`/c/...`)
  form while compiler flags use `C:/...` form; one of them may need to be unified.
- LAME compile errors from `configMS.h` typedefs (`int8_t` etc.) clashing with `<stdint.h>`;
  workaround is to compile with a patched copy of the generated `gen/config.h`, not the source.
- DLL major versions in file names (`avcodec-62.dll` ...) are globbed by CMake; CMake requires
  exactly five DLLs in `prebuilt/windows/bin`.
- Missing `vcruntime140.dll` / `msvcp140.dll` on machines without the VC++ redistributable (same as
  any Flutter Windows app).
- `dumpbin` output should list only system DLLs and the other FFmpeg/LAME DLLs.
- Unicode paths: FFmpeg's `file` protocol converts UTF-8 to UTF-16 on Windows; verify with a
  non-ASCII file name in the matrix test if the test fixtures use one.

## Open questions

- `docs/project_plan.md` §6.2 names `build_windows.ps1`; the task asked for `build_windows.sh`
  (MSYS2). Keep the `.sh` and update the plan, or add a PowerShell launcher? Not changed.
- Where Windows prebuilt artifacts live inside the pub package (`prebuilt/windows/`) and how
  `tool/fetch_prebuilt.sh` names the Release asset are not decided; this task assumes
  `prebuilt/windows/{bin,lib,include}`.

## First CI run (prebuilt workflow, 2026-10-22)

- MSVC environment, `link.exe` selection, source download and checksum verification worked.
- LAME failed: MSYS2 rewrote `-Fo"D:/a/..."` (`D:/a/x` became `A:\x`), so `cl` could not write
  `version.obj`. The comment in the script that dash-style options are safe was wrong. Fixed with
  `MSYS2_ARG_CONV_EXCL='*'` on the `cl` and `link` calls of `build_lame`, and `-DSTDC_HEADERS` was
  dropped (warning C4005: `configMS.h` already defines it).
- Pre-emptive, untested: `MSYS2_ARG_CONV_EXCL='-I;-LIBPATH:'` around FFmpeg's configure and make.

## Second CI run

- The `MSYS2_ARG_CONV_EXCL` fix worked: all LAME sources compiled.
- `link` failed with LNK2019 `init_xrpow_core_sse` (referenced by `quantize.c`), because the earlier
  assumption "SSE code is not built" was wrong (see the LAME decision above). Fixed by adding
  `libmp3lame/vector/xmm_quantize_sub.c` to the sources.
