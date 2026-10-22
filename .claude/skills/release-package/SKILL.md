---
name: release-package
description: Runs the pre-publish checks for su3_flutter_audio_converter on pub.dev
disable-model-invocation: true
---

1. Check that CHANGELOG.md and the version in pubspec.yaml match
2. Check with tool/fetch_prebuilt.sh that binaries for all OSes are present
3. Run the audit with the license-auditor subagent
4. Run `flutter analyze` and `flutter test`
5. Run `dart pub global run pana` and report any lost points
6. Run `dart pub publish --dry-run` and report the package size and warnings

Do not run the actual `dart pub publish`. Summarize the results for Su and stop.
