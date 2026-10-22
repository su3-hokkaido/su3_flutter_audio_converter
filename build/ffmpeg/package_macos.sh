#!/usr/bin/env bash
# Turn the universal dylibs from build_macos.sh into dynamic macOS frameworks, wrap each one in an
# XCFramework for the podspec (`vendored_frameworks`), and copy the public headers.
#
# Outputs (all git-ignored, see .gitignore):
#   macos/Frameworks/<name>.xcframework   linked and embedded by the macos podspec
#   prebuilt/include/                     FFmpeg and LAME headers used to compile src/
#
# Run build/ffmpeg/build_macos.sh first.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../versions.env
source "$root/build/versions.env"
in="$root/build/work/out/macos"
stage="$root/build/work/out/macos-frameworks"
dest="$root/macos/Frameworks"
names=(avutil swresample avcodec avformat mp3lame)

[ -d "$in/lib" ] || { echo "error: run build/ffmpeg/build_macos.sh first" >&2; exit 1; }

rm -rf "$stage" "$dest"
mkdir -p "$stage" "$dest" "$root/prebuilt"

for name in "${names[@]}"; do
  fw="$stage/$name.framework"
  mkdir -p "$fw/Versions/A/Resources"
  cp "$in/lib/lib$name.dylib" "$fw/Versions/A/$name"

  cat > "$fw/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>su3hokkaido.audioconverter.native.$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST

  ln -s A "$fw/Versions/Current"
  ln -s "Versions/Current/$name" "$fw/$name"
  ln -s Versions/Current/Resources "$fw/Resources"

  install_name_tool -id "@rpath/$name.framework/Versions/A/$name" "$fw/Versions/A/$name"
  for dep in "${names[@]}"; do
    install_name_tool -change "@rpath/lib$dep.dylib" \
      "@rpath/$dep.framework/Versions/A/$dep" "$fw/Versions/A/$name" 2>/dev/null || true
  done

  # An ad-hoc signature keeps the arm64 slice loadable after install_name_tool; Xcode re-signs
  # the framework with the app's identity when it is embedded.
  codesign --force --sign - "$fw"

  xcodebuild -create-xcframework -framework "$fw" -output "$dest/$name.xcframework"
done

rm -rf "$root/prebuilt/include"
cp -R "$in/include" "$root/prebuilt/include"

echo "XCFrameworks in $dest:"
du -sh "$dest"/*.xcframework
