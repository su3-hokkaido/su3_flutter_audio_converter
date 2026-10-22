# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(su3_flutter_audio_converter_library VERSION 0.0.1 LANGUAGES C)

add_library(su3_flutter_audio_converter SHARED
  "su3_flutter_audio_converter.c"
)

set_target_properties(su3_flutter_audio_converter PROPERTIES
  PUBLIC_HEADER su3_flutter_audio_converter.h
  OUTPUT_NAME "su3_flutter_audio_converter"
)

target_compile_definitions(su3_flutter_audio_converter PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(su3_flutter_audio_converter PRIVATE "-Wl,-z,max-page-size=16384")
endif()
