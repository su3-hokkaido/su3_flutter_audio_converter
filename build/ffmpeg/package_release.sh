#!/usr/bin/env bash
# Pack the staged prebuilt libraries of one platform into build/work/release/su3-prebuilt-<platform>.tar.gz
# (docs/project_plan.md section 6.2). The archive keeps repository-relative paths, so
# tool/fetch_prebuilt.sh only has to extract it at the repository root.
#
#   build/ffmpeg/package_release.sh macos|ios|android|windows
#
# Run the platform's build and package scripts first (they stage the files below).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
platform="${1:-}"

case "$platform" in
  macos)   paths=(macos/Frameworks prebuilt/include) ;;
  ios)     paths=(ios/Frameworks prebuilt/include) ;;
  android) paths=(android/src/main/jniLibs prebuilt/include) ;;
  windows) paths=(prebuilt/windows) ;;
  *) echo "usage: $0 macos|ios|android|windows" >&2; exit 1 ;;
esac

for p in "${paths[@]}"; do
  [ -d "$root/$p" ] || { echo "error: $p is missing; build and package $platform first" >&2; exit 1; }
done

# The license texts of FFmpeg (LGPL) and LAME (LGPL) travel with the binaries, from the verified
# source tarballs (build/ffmpeg/fetch_sources.sh or build_windows.sh downloaded them).
source "$root/build/versions.env"
out="$root/build/work/release"
lic="$out/licenses-$platform"
rm -rf "$lic"
mkdir -p "$out" "$lic/prebuilt/licenses/ffmpeg" "$lic/prebuilt/licenses/lame"
tar -xJf "$root/build/work/src/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$lic/prebuilt/licenses/ffmpeg" \
  --strip-components=1 "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv3" \
  "ffmpeg-$FFMPEG_VERSION/LICENSE.md"
tar -xzf "$root/build/work/src/lame-$LAME_VERSION.tar.gz" -C "$lic/prebuilt/licenses/lame" \
  --strip-components=1 "lame-$LAME_VERSION/COPYING" "lame-$LAME_VERSION/LICENSE"

archive="$out/su3-prebuilt-$platform.tar.gz"
tar -czf "$archive" -C "$root" "${paths[@]}" -C "$lic" prebuilt/licenses
rm -rf "$lic"
echo "Created $archive"
ls -l "$archive"
