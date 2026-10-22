#!/usr/bin/env bash
# Turn the dylibs from build_ios.sh into dynamic iOS frameworks (flat layout), wrap each library in
# an XCFramework (ios-arm64 and ios-arm64_x86_64-simulator) for the podspec
# (`vendored_frameworks`), and copy the public headers.
#
# Outputs (all git-ignored, see .gitignore):
#   ios/Frameworks/<name>.xcframework   linked and embedded by the ios podspec
#   prebuilt/include/                   FFmpeg and LAME headers used to compile src/
#
# Run build/ffmpeg/build_ios.sh first.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
in="$root/build/work/out/ios"
stage="$root/build/work/out/ios-frameworks"
dest="$root/ios/Frameworks"
names=(avutil swresample avcodec avformat mp3lame)

[ -d "$in/device/lib" ] || { echo "error: run build/ffmpeg/build_ios.sh first" >&2; exit 1; }

rm -rf "$stage" "$dest"
mkdir -p "$stage" "$dest" "$root/prebuilt"

for name in "${names[@]}"; do
  args=()
  for variant in device simulator; do
    if [ "$variant" = "device" ]; then platform="iPhoneOS"; else platform="iPhoneSimulator"; fi
    fw="$stage/$variant/$name.framework"
    mkdir -p "$fw"
    cp "$in/$variant/lib/lib$name.dylib" "$fw/$name"

    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>su3hokkaido.audioconverter.native.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST

    install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    for dep in "${names[@]}"; do
      # Fails only when the library does not reference $dep, which is expected for most pairs.
      install_name_tool -change "@rpath/lib$dep.dylib" \
        "@rpath/$dep.framework/$dep" "$fw/$name" 2>/dev/null || true
    done
    # No reference to a bare dylib may remain, or dyld fails at load time.
    if otool -L "$fw/$name" | grep -q '@rpath/lib.*\.dylib'; then
      echo "error: $fw/$name still references @rpath/lib*.dylib" >&2
      exit 1
    fi

    # An ad-hoc signature keeps the arm64 slices loadable after install_name_tool; Xcode re-signs
    # the framework with the app's identity when it is embedded.
    codesign --force --sign - "$fw"
    args+=(-framework "$fw")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$dest/$name.xcframework"
done

rm -rf "$root/prebuilt/include"
cp -R "$in/include" "$root/prebuilt/include"

echo "XCFrameworks in $dest:"
du -sh "$dest"/*.xcframework
