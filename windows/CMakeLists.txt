# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# UNVERIFIED: written without the ability to build on Windows (see
# docs/2026-10-22_04_m4-windows/design.md).

# Project-level configuration.
set(PROJECT_NAME "su3_flutter_audio_converter")
project(${PROJECT_NAME} LANGUAGES CXX)

# Prebuilt FFmpeg and LAME for Windows x64 (never committed to git). Created by
# build/ffmpeg/build_windows.sh, or fetched from GitHub Releases.
#   bin/      avutil-*.dll, swresample-*.dll, avcodec-*.dll, avformat-*.dll, libmp3lame.dll
#   lib/      import libraries: avformat.lib avcodec.lib swresample.lib avutil.lib mp3lame.lib
#   include/  FFmpeg and LAME headers
set(SU3_PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/windows")
foreach(_su3_lib avformat avcodec swresample avutil mp3lame)
  if(NOT EXISTS "${SU3_PREBUILT_DIR}/lib/${_su3_lib}.lib")
    message(FATAL_ERROR
      "Missing ${SU3_PREBUILT_DIR}/lib/${_su3_lib}.lib. Build the Windows FFmpeg/LAME DLLs with "
      "build/ffmpeg/build_windows.sh (see docs/2026-10-22_04_m4-windows/design.md).")
  endif()
endforeach()

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# The wrapper is compiled from source here (decision #17) and links the prebuilt import libraries,
# so FFmpeg and LAME stay separate DLLs (LGPL relinking). The wrapper's exports come from
# FFI_PLUGIN_EXPORT (__declspec(dllexport)) in su3_flutter_audio_converter.h.
target_include_directories(su3_flutter_audio_converter PRIVATE "${SU3_PREBUILT_DIR}/include")
target_link_libraries(su3_flutter_audio_converter PRIVATE
  "${SU3_PREBUILT_DIR}/lib/avformat.lib"
  "${SU3_PREBUILT_DIR}/lib/avcodec.lib"
  "${SU3_PREBUILT_DIR}/lib/swresample.lib"
  "${SU3_PREBUILT_DIR}/lib/avutil.lib"
  "${SU3_PREBUILT_DIR}/lib/mp3lame.lib"
)

# FFmpeg DLL file names carry the library major version (for example avcodec-62.dll), so they are
# found with a glob instead of being hard-coded.
file(GLOB SU3_PREBUILT_DLLS "${SU3_PREBUILT_DIR}/bin/*.dll")
list(LENGTH SU3_PREBUILT_DLLS _su3_dll_count)
if(NOT _su3_dll_count EQUAL 5)
  message(FATAL_ERROR
    "Expected 5 DLLs in ${SU3_PREBUILT_DIR}/bin (avutil, swresample, avcodec, avformat, "
    "libmp3lame), found ${_su3_dll_count}.")
endif()

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(su3_flutter_audio_converter_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  $<TARGET_FILE:su3_flutter_audio_converter>
  # Prebuilt FFmpeg and LAME DLLs, installed next to the app executable.
  ${SU3_PREBUILT_DLLS}
  PARENT_SCOPE
)
