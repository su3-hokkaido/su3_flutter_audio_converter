---
name: conversion-matrix-test
description: Run the 5x5 format conversions across the supported bitrates and report the probe results as a table. Use to verify the converter after native or build changes.
---

1. Make sure the native library for the current OS is present (`tool/fetch_prebuilt.sh` or a local
   build). If not, stop and say so.
2. Run the matrix test (`flutter test test/conversion_matrix_test.dart`, or the integration test in
   `example/` when a device is needed). Inputs are the self-made clips in `example/assets/fixtures/`.
3. For every pair of mp3, m4a, wma, wav, aac (25 pairs, same-format included) and each supported
   bitrate (128 / 192 / 256 / 320; none for wav), read the output back with `probe`.
4. Report a table: input, output, bitrate, result (pass/fail/skipped), probed format, duration
   versus expected (with tolerance), probed bitrate, sample rate, channels.
5. Check that no temporary or partial files remain in the output and temp directories.
6. WMA 320 kbps is not offered (plan §8.1 #16); confirm it is rejected rather than converted.
