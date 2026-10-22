import 'package:flutter_test/flutter_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

/// The table of docs/project_plan.md section 3.2 (and C comment of su3_convert_options).
const Map<AudioFormat, List<int>> _plan = <AudioFormat, List<int>>{
  AudioFormat.mp3: <int>[128, 192, 256, 320],
  AudioFormat.m4a: <int>[128, 192, 256, 320],
  AudioFormat.aac: <int>[128, 192, 256, 320],
  AudioFormat.wma: <int>[128, 192, 256],
  AudioFormat.wav: <int>[],
};

void main() {
  final AudioConverter converter = AudioConverter();

  test('the table covers every format', () {
    expect(_plan.keys, unorderedEquals(AudioFormat.values));
  });

  for (final AudioFormat format in AudioFormat.values) {
    test('supportedBitrates(${format.name}) matches plan section 3.2', () {
      expect(converter.supportedBitrates(format), _plan[format]);
    });
  }

  test('input info only narrows mp3', () {
    const AudioInfo mono = AudioInfo(
      format: AudioFormat.wav,
      duration: Duration(seconds: 1),
      sampleRate: 8000,
      channels: 1,
      bitrateKbps: 128,
    );
    for (final AudioFormat format in AudioFormat.values) {
      expect(
        converter.supportedBitrates(format, input: mono),
        format == AudioFormat.mp3 ? <int>[128] : _plan[format],
      );
    }
  });

  test('320 is offered everywhere except wma and wav', () {
    for (final AudioFormat format in AudioFormat.values) {
      expect(
        converter.supportedBitrates(format).contains(320),
        format != AudioFormat.wma && format != AudioFormat.wav,
      );
    }
  });

  test('the default bitrate is 128 and is in every lossy list', () {
    expect(ConvertOptions.defaultBitrateKbps, 128);
    for (final AudioFormat format in AudioFormat.values) {
      if (format == AudioFormat.wav) continue;
      expect(converter.supportedBitrates(format).first, 128);
    }
  });

  group('mp3 narrowing by input sample rate', () {
    AudioInfo at(int rate) => AudioInfo(
      format: AudioFormat.wav,
      duration: const Duration(seconds: 1),
      sampleRate: rate,
      channels: 2,
      bitrateKbps: null,
    );

    test('offers every value from 32 kHz up', () {
      for (final int rate in <int>[32000, 44100, 48000]) {
        expect(
          converter.supportedBitrates(AudioFormat.mp3, input: at(rate)),
          <int>[128, 192, 256, 320],
        );
      }
    });

    test('offers only 128 below 32 kHz (MPEG-2 and 2.5 caps)', () {
      for (final int rate in <int>[8000, 12000, 16000, 22050, 24000]) {
        expect(
          converter.supportedBitrates(AudioFormat.mp3, input: at(rate)),
          <int>[128],
        );
      }
    });

    test('does not narrow other formats', () {
      for (final AudioFormat format in <AudioFormat>[
        AudioFormat.m4a,
        AudioFormat.aac,
        AudioFormat.wma,
      ]) {
        expect(
          converter.supportedBitrates(format, input: at(22050)),
          converter.supportedBitrates(format),
        );
      }
    });
  });

  for (final AudioFormat format in AudioFormat.values) {
    if (format == AudioFormat.wav) continue;
    test('${format.name} rejects unlisted values before any native call', () {
      for (final int bad in <int>[0, 64, 100, 129, 384, -128]) {
        expect(
          converter.convert(
            inputPath: 'in.wav',
            outputPath: 'out.${format.fileExtension}',
            options: ConvertOptions(outputFormat: format, bitrateKbps: bad),
          ),
          throwsA(isA<UnsupportedBitrateException>()),
          reason: '$bad kbps',
        );
      }
    });
  }
}
