import 'package:flutter_test/flutter_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

void main() {
  group('ConvertOptions', () {
    test('defaults to 128 kbps', () {
      const ConvertOptions options = ConvertOptions(
        outputFormat: AudioFormat.mp3,
      );
      expect(options.bitrateKbps, isNull);
      expect(options.effectiveBitrateKbps, 128);
    });

    test('keeps an explicit bitrate', () {
      const ConvertOptions options = ConvertOptions(
        outputFormat: AudioFormat.aac,
        bitrateKbps: 256,
      );
      expect(options.effectiveBitrateKbps, 256);
    });
  });

  group('CancelToken', () {
    test('notifies listeners once', () {
      final CancelToken token = CancelToken();
      int calls = 0;
      token.addListener(() => calls++);

      expect(token.isCancelled, isFalse);
      token.cancel();
      token.cancel();

      expect(token.isCancelled, isTrue);
      expect(calls, 1);
    });

    test('does not notify removed listeners', () {
      final CancelToken token = CancelToken();
      int calls = 0;
      void listener() => calls++;
      token.addListener(listener);
      token.removeListener(listener);

      token.cancel();

      expect(calls, 0);
    });
  });

  group('supportedBitrates', () {
    final AudioConverter converter = AudioConverter();

    test('wav has no bitrate options', () {
      expect(converter.supportedBitrates(AudioFormat.wav), isEmpty);
    });

    test('wma is limited to 128, 192 and 256', () {
      expect(converter.supportedBitrates(AudioFormat.wma), <int>[
        128,
        192,
        256,
      ]);
    });

    test('mp3, m4a and aac offer all four values', () {
      for (final AudioFormat format in <AudioFormat>[
        AudioFormat.mp3,
        AudioFormat.m4a,
        AudioFormat.aac,
      ]) {
        expect(converter.supportedBitrates(format), <int>[128, 192, 256, 320]);
      }
    });

    test('the default bitrate is offered for every compressed format', () {
      for (final AudioFormat format in AudioFormat.values) {
        if (format == AudioFormat.wav) continue;
        expect(
          converter.supportedBitrates(format),
          contains(ConvertOptions.defaultBitrateKbps),
        );
      }
    });
  });

  group('convert validation (no native call is made)', () {
    final AudioConverter converter = AudioConverter();

    test('rejects 320 kbps for wma', () {
      expect(
        converter.convert(
          inputPath: 'in.wav',
          outputPath: 'out.wma',
          options: const ConvertOptions(
            outputFormat: AudioFormat.wma,
            bitrateKbps: 320,
          ),
        ),
        throwsA(isA<UnsupportedBitrateException>()),
      );
    });

    test('rejects a bitrate that is not offered', () {
      expect(
        converter.convert(
          inputPath: 'in.wav',
          outputPath: 'out.mp3',
          options: const ConvertOptions(
            outputFormat: AudioFormat.mp3,
            bitrateKbps: 100,
          ),
        ),
        throwsA(isA<UnsupportedBitrateException>()),
      );
    });

    test('fails immediately for a token cancelled beforehand', () {
      expect(
        converter.convert(
          inputPath: 'in.wav',
          outputPath: 'out.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
          cancelToken: CancelToken()..cancel(),
        ),
        throwsA(isA<ConversionCancelledException>()),
      );
    });
  });

  test('every exception is a ConversionException', () {
    const List<ConversionException> all = <ConversionException>[
      UnsupportedFormatException('a'),
      UnsupportedBitrateException('b'),
      CorruptedFileException('c'),
      ConversionCancelledException(),
    ];
    expect(
      all.map((ConversionException e) => e.toString()),
      everyElement(isNotEmpty),
    );
  });
}
