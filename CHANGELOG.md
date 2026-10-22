## 0.0.1

- Unreleased. Work in progress.
- Package scaffold (Flutter FFI plugin) for iOS, Android, macOS and Windows; only macOS builds so far.
- `AudioConverter.convert` converts between all 5 x 5 formats (mp3, m4a, wma, wav, aac) with progress
  and cancellation; macOS only so far.
- `AudioConverter.probe` / `AudioInfo`, `supportedBitrates(format, {input})` (MP3 is narrowed to 128
  kbps for input below 32 kHz), and `resolveUniqueOutputPath`.
