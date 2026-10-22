import 'audio_format.dart';

/// Properties of an audio file as reported by `AudioConverter.probe`.
class AudioInfo {
  const AudioInfo({
    required this.format,
    required this.duration,
    required this.sampleRate,
    required this.channels,
    required this.bitrateKbps,
  });

  /// Container format detected from the file content (not from its extension).
  final AudioFormat format;

  /// Duration, or null when the file does not state one.
  final Duration? duration;

  /// Sample rate in Hz, or null when unknown.
  final int? sampleRate;

  /// Number of channels, or null when unknown.
  final int? channels;

  /// Bitrate of the audio stream in kbps, or null when unknown.
  final int? bitrateKbps;

  @override
  String toString() =>
      'AudioInfo(format: ${format.name}, duration: $duration, '
      'sampleRate: $sampleRate, channels: $channels, bitrateKbps: $bitrateKbps)';
}
