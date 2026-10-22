---
name: add-audio-format
description: Steps for adding a new audio format (for example 3GP later) to the package. User-invoked only.
disable-model-invocation: true
---

Adding a format touches several places. Confirm scope with the user first (3GP is out of scope in
the initial version, `docs/project_plan.md` §3.1).

1. Add the value to `AudioFormat` and its extension/MIME mapping.
2. Update FFmpeg configure flags (`.claude/skills/ffmpeg-build/configure-flags.md` and the build
   scripts): demuxer, muxer, decoder, encoder, parser. Stay LGPL; report anything outside §5.3 and
   record the decision in `docs/project_plan.md`.
3. Update the C wrapper mapping from `AudioFormat` to muxer/encoder and regenerate bindings if the
   header changed (`regenerate-bindings` skill).
4. Update the bitrate table behind `supportedBitrates(format, {input})`.
5. Extend the conversion matrix tests and fixtures (`conversion-matrix-test` skill).
6. Update README, CHANGELOG and the `licenses/` notices.
7. Run `flutter analyze`, `flutter test`, then the `code-reviewer` and `license-auditor` agents.
