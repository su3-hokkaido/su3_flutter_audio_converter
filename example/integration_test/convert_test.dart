import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';
import 'package:su3_flutter_audio_converter_example/sample_wav.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final AudioConverter converter = AudioConverter();

  setUp(() => dir = Directory.systemTemp.createTempSync('su3_it_'));
  tearDown(() => dir.deleteSync(recursive: true));

  bool looksLikeMp3(String path) {
    final List<int> head = File(path).openSync().readSync(3);
    final bool id3 = head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;
    final bool frameSync = head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
    return id3 || frameSync;
  }

  testWidgets('converts a wav file to mp3 and reports progress', (_) async {
    final String input = await writeSampleWav(
      '${dir.path}/in.wav',
      seconds: 20,
    );
    final List<double> progress = <double>[];

    final String output = await converter.convert(
      inputPath: input,
      outputPath: '${dir.path}/out.mp3',
      options: const ConvertOptions(outputFormat: AudioFormat.mp3),
      onProgress: progress.add,
    );

    expect(output, '${dir.path}/out.mp3');
    expect(File(output).existsSync(), isTrue);
    // 20 s at 128 kbps is about 320 kB.
    expect(File(output).lengthSync(), inInclusiveRange(250000, 400000));
    expect(looksLikeMp3(output), isTrue);
    expect(progress, isNotEmpty);
    expect(progress.every((double p) => p >= 0 && p <= 1), isTrue);
    expect(progress, orderedEquals(List<double>.of(progress)..sort()));
  });

  testWidgets('honours the bitrate', (_) async {
    final String input = await writeSampleWav(
      '${dir.path}/in.wav',
      seconds: 20,
    );
    for (final int kbps in <int>[128, 320]) {
      final String output = await converter.convert(
        inputPath: input,
        outputPath: '${dir.path}/out_$kbps.mp3',
        options: ConvertOptions(
          outputFormat: AudioFormat.mp3,
          bitrateKbps: kbps,
        ),
      );
      final int expected = 20 * kbps * 1000 ~/ 8;
      expect(File(output).lengthSync(), closeTo(expected, expected * 0.15));
    }
  });

  testWidgets('cancellation fails the future and leaves no output', (_) async {
    final String input = await writeSampleWav(
      '${dir.path}/long.wav',
      seconds: 600,
    );
    final CancelToken token = CancelToken();
    final Future<String> result = converter.convert(
      inputPath: input,
      outputPath: '${dir.path}/cancelled.mp3',
      options: const ConvertOptions(
        outputFormat: AudioFormat.mp3,
        bitrateKbps: 320,
      ),
      onProgress: (double progress) {
        if (progress > 0.02) token.cancel();
      },
      cancelToken: token,
    );

    await expectLater(result, throwsA(isA<ConversionCancelledException>()));
    expect(File('${dir.path}/cancelled.mp3').existsSync(), isFalse);
  });

  testWidgets('a token cancelled beforehand never starts a job', (_) async {
    final CancelToken token = CancelToken()..cancel();
    await expectLater(
      converter.convert(
        inputPath: '${dir.path}/unused.wav',
        outputPath: '${dir.path}/unused.mp3',
        options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        cancelToken: token,
      ),
      throwsA(isA<ConversionCancelledException>()),
    );
  });

  testWidgets(
    'a missing input fails with a plain ConversionException (code 2)',
    (_) async {
      await expectLater(
        converter.convert(
          inputPath: '${dir.path}/missing.wav',
          outputPath: '${dir.path}/missing.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        ),
        // SU3_ERR_OPEN_INPUT (2) has no subclass of its own.
        throwsA(
          isA<ConversionException>()
              .having((e) => e.runtimeType, 'type', ConversionException)
              .having((e) => e.nativeErrorCode, 'nativeErrorCode', 2),
        ),
      );
      expect(File('${dir.path}/missing.mp3').existsSync(), isFalse);
    },
  );

  testWidgets(
    'a garbage input is an UnsupportedFormatException without output',
    (_) async {
      File(
        '${dir.path}/garbage.wav',
      ).writeAsBytesSync(List<int>.generate(4096, (int i) => (i * 31) & 0xFF));
      await expectLater(
        converter.convert(
          inputPath: '${dir.path}/garbage.wav',
          outputPath: '${dir.path}/garbage.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        ),
        throwsA(isA<UnsupportedFormatException>()),
      );
      expect(File('${dir.path}/garbage.mp3').existsSync(), isFalse);
    },
  );

  testWidgets('several conversions can run at the same time', (_) async {
    final String input = await writeSampleWav(
      '${dir.path}/in.wav',
      seconds: 10,
    );
    final List<String> outputs = await Future.wait(<Future<String>>[
      for (int i = 0; i < 4; i++)
        converter.convert(
          inputPath: input,
          outputPath: '${dir.path}/parallel_$i.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        ),
    ]);
    for (final String output in outputs) {
      expect(looksLikeMp3(output), isTrue);
    }
  });
}
