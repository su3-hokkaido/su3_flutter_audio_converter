import 'audio_format.dart';

/// Options of one conversion.
class ConvertOptions {
  const ConvertOptions({required this.outputFormat, this.bitrateKbps});

  /// Bitrate used when [bitrateKbps] is not given.
  static const int defaultBitrateKbps = 128;

  final AudioFormat outputFormat;

  /// Target bitrate in kbps, or null for [defaultBitrateKbps]. Ignored for WAV. A value that is
  /// not in `AudioConverter.supportedBitrates` is an error.
  final int? bitrateKbps;

  // Planned for later: bool preserveMetadata (docs/project_plan.md section 3.4).

  int get effectiveBitrateKbps => bitrateKbps ?? defaultBitrateKbps;
}
