# Android build of the C wrapper. It compiles ../src and links it against the prebuilt FFmpeg and
# LAME shared libraries in src/main/jniLibs/<abi>/ (built by build/ffmpeg/build_android.sh or
# fetched from GitHub Releases; never committed). The same .so files are packaged into the APK by
# the Android Gradle Plugin because they sit in jniLibs.
#
# This file is separate from ../src/CMakeLists.txt, which the Windows build uses.
cmake_minimum_required(VERSION 3.10)

project(su3_flutter_audio_converter_android LANGUAGES C)

set(SU3_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")
set(SU3_PREBUILT_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/include")
set(SU3_JNI_LIBS "${CMAKE_CURRENT_SOURCE_DIR}/src/main/jniLibs/${ANDROID_ABI}")

foreach(lib avformat avcodec swresample avutil mp3lame)
  if(NOT EXISTS "${SU3_JNI_LIBS}/lib${lib}.so")
    message(FATAL_ERROR
      "Missing ${SU3_JNI_LIBS}/lib${lib}.so. Run build/ffmpeg/build_android.sh "
      "or tool/fetch_prebuilt.sh first.")
  endif()
  add_library(${lib} SHARED IMPORTED)
  set_target_properties(${lib} PROPERTIES
    IMPORTED_LOCATION "${SU3_JNI_LIBS}/lib${lib}.so")
endforeach()

add_library(su3_flutter_audio_converter SHARED
  "${SU3_SRC_DIR}/su3_flutter_audio_converter.c"
)

target_include_directories(su3_flutter_audio_converter PRIVATE
  "${SU3_SRC_DIR}"
  "${SU3_PREBUILT_INCLUDE}"
)

target_compile_definitions(su3_flutter_audio_converter PUBLIC DART_SHARED_LIB)

target_link_libraries(su3_flutter_audio_converter PRIVATE
  avformat avcodec swresample avutil mp3lame m
)

# Support Android 15 16 KB page size.
target_link_options(su3_flutter_audio_converter PRIVATE "-Wl,-z,max-page-size=16384")
