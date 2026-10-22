#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint su3_flutter_audio_converter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'su3_flutter_audio_converter'
  s.version          = '0.0.1'
  s.summary          = 'Converts audio files on the device with a bundled minimal FFmpeg.'
  s.description      = <<-DESC
Converts mp3, m4a, wma, wav and aac files entirely on the device through dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/su3-hokkaido/su3_flutter_audio_converter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Su3' => 'su3.hokkaido.2210@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  # The prebuilt FFmpeg and LAME frameworks (build/ffmpeg/package_ios.sh creates them; they are
  # git-ignored and bundled when the package is published). They are linked dynamically (LGPL).
  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Headers of the prebuilt libraries, shared by all platforms.
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../prebuilt/include"',
    'OTHER_LDFLAGS' => '-framework avformat -framework avcodec -framework swresample -framework avutil',
  }
  s.swift_version = '5.0'
end
