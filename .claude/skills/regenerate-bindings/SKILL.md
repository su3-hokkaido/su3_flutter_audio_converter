---
name: regenerate-bindings
description: Regenerate the dart:ffi bindings with ffigen after a C header change, review the diff and run flutter analyze. Use after editing the public header in src/.
---

1. Confirm the C header in `src/` is the intended change (the public surface should stay minimal:
   probe, convert_start, convert_cancel, last_error).
2. Run `dart run ffigen --config ffigen.yaml`. Never edit the generated file by hand (the guard
   hook blocks it).
3. Review the diff of the generated file with `git diff`: only expected symbols changed, no
   unexpected removals or renamed types.
4. Update the hand-written Dart wrapper if signatures changed.
5. Run `flutter analyze` and `flutter test`; report results.
6. The generated file is committed, but do not commit it yourself; present the diff for the user.

If `ffigen.yaml` is missing or ffigen is not a dev dependency, report it instead of guessing the
configuration, and check current `ffigen` docs via Context7.
