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

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'su3_flutter_audio_converter_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  # The prebuilt FFmpeg and LAME frameworks (build/ffmpeg/package_macos.sh creates them; they are
  # git-ignored and bundled when the package is published). They are linked dynamically (LGPL).
  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Headers of the prebuilt libraries, shared by all platforms.
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../prebuilt/include"',
    'OTHER_LDFLAGS' => '-framework avformat -framework avcodec -framework swresample -framework avutil',
  }
  s.swift_version = '5.0'
end
