import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Writes a self-made 16-bit PCM sine wave to [path] and returns it. Nothing here is third-party
/// audio, so there is nothing to license.
Future<String> writeSampleWav(
  String path, {
  required double seconds,
  int sampleRate = 44100,
  int channels = 2,
}) {
  return Isolate.run(() {
    final int frames = (sampleRate * seconds).round();
    final int dataBytes = frames * channels * 2;
    final ByteData data = ByteData(44 + dataBytes);
    void tag(int offset, String text) {
      for (int i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVEfmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * channels * 2, Endian.little);
    data.setUint16(32, channels * 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, dataBytes, Endian.little);
    int offset = 44;
    for (int i = 0; i < frames; i++) {
      final int sample = (12000 * math.sin(2 * math.pi * 440 * i / sampleRate))
          .round();
      for (int c = 0; c < channels; c++) {
        data.setInt16(offset, sample, Endian.little);
        offset += 2;
      }
    }
    File(path).writeAsBytesSync(data.buffer.asUint8List());
    return path;
  });
}
