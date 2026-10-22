// Conversion matrix and edge cases against the real native library. Runs inside the macOS example
// app: cd example && flutter test integration_test -d macos
//
// The inputs are the self-made fixtures of test/fixtures/ (see its README.md), bundled as assets.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';
import 'package:su3_flutter_audio_converter_example/sample_wav.dart';

/// Properties of the fixtures (tool/make_fixtures.c): 1 s, mono, 22.05 kHz.
const int _fixtureRate = 22050;
const int _fixtureChannels = 1;
const Duration _fixtureDuration = Duration(seconds: 1);

/// Frame padding and encoder delay of the lossy codecs; generous on purpose.
const Duration _durationTolerance = Duration(milliseconds: 250);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final AudioConverter converter = AudioConverter();
  late Directory dir;
  late Directory fixtureDir;

  setUpAll(() async {
    fixtureDir = Directory.systemTemp.createTempSync('su3_fixtures_');
    for (final AudioFormat format in AudioFormat.values) {
      final String name = 'tone.${format.fileExtension}';
      final ByteData data = await rootBundle.load('../test/fixtures/$name');
      File('${fixtureDir.path}/$name').writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
  });
  tearDownAll(() => fixtureDir.deleteSync(recursive: true));

  setUp(() => dir = Directory.systemTemp.createTempSync('su3_matrix_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String fixture(AudioFormat format) =>
      '${fixtureDir.path}/tone.${format.fileExtension}';

  /// Names of the entries in [dir], sorted.
  List<String> listing() =>
      dir
          .listSync()
          .map(
            (FileSystemEntity e) =>
                e.uri.pathSegments.where((s) => s.isNotEmpty).last,
          )
          .toList()
        ..sort();

  /// Allowed bitrate range (kbps) of an output made at [kbps] from the 1 s fixture.
  ///
  /// MP3 and WMA are constant bitrate and land close. FFmpeg's built-in AAC encoder undershoots
  /// on simple signals at high targets, so the lower bound for m4a/aac is generous.
  (double, double) bitrateRange(AudioFormat format, int kbps, int sampleRate) {
    // MPEG-2 Layer III (below 32 kHz) has no frame size above 160 kbps, so LAME clamps higher
    // targets there; supportedBitrates narrows MP3 to 128 for such input.
    final int mp3Kbps = sampleRate < 32000 && kbps > 160 ? 160 : kbps;
    return switch (format) {
      AudioFormat.mp3 => (mp3Kbps * 0.85, mp3Kbps * 1.15),
      AudioFormat.wma => (kbps * 0.80, kbps * 1.20),
      AudioFormat.m4a || AudioFormat.aac => (kbps * 0.20, kbps * 1.30),
      AudioFormat.wav => (0, double.infinity),
    };
  }

  void expectInfo(
    AudioInfo info, {
    required AudioFormat format,
    required Duration duration,
    required int sampleRate,
    required int channels,
    int? kbps,
  }) {
    expect(info.format, format, reason: '$info');
    expect(info.duration, isNotNull, reason: '$info');
    expect(
      (info.duration! - duration).inMilliseconds.abs(),
      lessThanOrEqualTo(_durationTolerance.inMilliseconds),
      reason: '$info',
    );
    expect(info.sampleRate, sampleRate, reason: '$info');
    expect(info.channels, channels, reason: '$info');
    if (format == AudioFormat.wav) {
      // PCM bitrate is exact: rate * channels * 16 bit.
      expect(
        info.bitrateKbps,
        (sampleRate * channels * 16 / 1000).round(),
        reason: '$info',
      );
    } else if (kbps != null) {
      final (double low, double high) = bitrateRange(format, kbps, sampleRate);
      expect(info.bitrateKbps, isNotNull, reason: '$info');
      expect(
        info.bitrateKbps!.toDouble(),
        inInclusiveRange(low, high),
        reason: '$info at $kbps kbps',
      );
    }
  }

  group('5x5 matrix (default 128 kbps)', () {
    for (final AudioFormat from in AudioFormat.values) {
      for (final AudioFormat to in AudioFormat.values) {
        testWidgets('${from.name} -> ${to.name}', (_) async {
          final String output = '${dir.path}/out.${to.fileExtension}';
          final String result = await converter.convert(
            inputPath: fixture(from),
            outputPath: output,
            options: ConvertOptions(outputFormat: to),
          );
          expect(result, output);
          final AudioInfo info = await converter.probe(output);
          expectInfo(
            info,
            format: to,
            duration: _fixtureDuration,
            sampleRate: _fixtureRate,
            channels: _fixtureChannels,
            kbps: to == AudioFormat.wav ? null : 128,
          );
          expect(listing(), <String>['out.${to.fileExtension}']);
        });
      }
    }
  });

  group('bitrates', () {
    for (final AudioFormat to in AudioFormat.values) {
      if (to == AudioFormat.wav) continue;
      // The fixtures are 22.05 kHz, where MP3 offers only 128 kbps (see supportedBitrates).
      final List<int> offered = converter.supportedBitrates(
        to,
        input: AudioInfo(
          format: AudioFormat.wav,
          duration: _fixtureDuration,
          sampleRate: _fixtureRate,
          channels: _fixtureChannels,
          bitrateKbps: null,
        ),
      );
      for (final int kbps in offered) {
        testWidgets('wav -> ${to.name} at $kbps kbps', (_) async {
          final String output = await converter.convert(
            inputPath: fixture(AudioFormat.wav),
            outputPath: '${dir.path}/out.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to, bitrateKbps: kbps),
          );
          expectInfo(
            await converter.probe(output),
            format: to,
            duration: _fixtureDuration,
            sampleRate: _fixtureRate,
            channels: _fixtureChannels,
            kbps: kbps,
          );
        });
      }
    }

    testWidgets('a higher bitrate gives a larger mp3 and (overall) wma', (
      _,
    ) async {
      // 44.1 kHz so that MP3 really offers all four values (see bitrateRange).
      final String input = await writeSampleWav(
        '${dir.path}/in44.wav',
        seconds: 2,
      );
      for (final AudioFormat to in <AudioFormat>[
        AudioFormat.mp3,
        AudioFormat.wma,
      ]) {
        final List<int> sizes = <int>[];
        for (final int kbps in converter.supportedBitrates(to)) {
          final String output = await converter.convert(
            inputPath: input,
            outputPath: '${dir.path}/size_$kbps.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to, bitrateKbps: kbps),
          );
          sizes.add(File(output).lengthSync());
        }
        expect(
          sizes,
          orderedEquals(List<int>.of(sizes)..sort()),
          reason: to.name,
        );
        // MP3 is strictly constant bitrate. FFmpeg's WMAv2 encoder snaps to a few classes: 192 and
        // 256 kbps give the same size, so only require that the range grows overall.
        if (to == AudioFormat.mp3) {
          expect(sizes.toSet().length, sizes.length, reason: to.name);
        } else {
          expect(sizes.last, greaterThan(sizes.first), reason: to.name);
        }
      }
    });

    testWidgets('mp3 above 128 kbps is rejected for input below 32 kHz', (
      _,
    ) async {
      final AudioInfo info = await converter.probe(fixture(AudioFormat.wav));
      expect(converter.supportedBitrates(AudioFormat.mp3, input: info), <int>[
        128,
      ]);
      await expectLater(
        converter.convert(
          inputPath: fixture(AudioFormat.wav),
          outputPath: '${dir.path}/out.mp3',
          options: const ConvertOptions(
            outputFormat: AudioFormat.mp3,
            bitrateKbps: 192,
          ),
        ),
        throwsA(isA<UnsupportedBitrateException>()),
      );
      expect(listing(), isEmpty);
    });

    testWidgets('wma at 320 kbps is rejected before any native call', (
      _,
    ) async {
      await expectLater(
        converter.convert(
          inputPath: fixture(AudioFormat.wav),
          outputPath: '${dir.path}/out.wma',
          options: const ConvertOptions(
            outputFormat: AudioFormat.wma,
            bitrateKbps: 320,
          ),
        ),
        throwsA(isA<UnsupportedBitrateException>()),
      );
      expect(listing(), isEmpty);
    });

    testWidgets('an unlisted bitrate is rejected for every lossy format', (
      _,
    ) async {
      for (final AudioFormat to in AudioFormat.values) {
        if (to == AudioFormat.wav) continue;
        await expectLater(
          converter.convert(
            inputPath: fixture(AudioFormat.wav),
            outputPath: '${dir.path}/out.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to, bitrateKbps: 100),
          ),
          throwsA(isA<UnsupportedBitrateException>()),
          reason: to.name,
        );
      }
      expect(listing(), isEmpty);
    });

    testWidgets('the bitrate is ignored for wav', (_) async {
      final String output = await converter.convert(
        inputPath: fixture(AudioFormat.mp3),
        outputPath: '${dir.path}/out.wav',
        options: const ConvertOptions(
          outputFormat: AudioFormat.wav,
          bitrateKbps: 192,
        ),
      );
      expect((await converter.probe(output)).format, AudioFormat.wav);
    });
  });

  group('same format', () {
    for (final AudioFormat format in AudioFormat.values) {
      if (format == AudioFormat.wav) continue;
      // MP3 from 22.05 kHz input only offers 128 kbps.
      final int kbps = format == AudioFormat.mp3 ? 128 : 192;
      testWidgets('${format.name} re-encoded at $kbps kbps', (_) async {
        final String output = await converter.convert(
          inputPath: fixture(format),
          outputPath: '${dir.path}/again.${format.fileExtension}',
          options: ConvertOptions(outputFormat: format, bitrateKbps: kbps),
        );
        expectInfo(
          await converter.probe(output),
          format: format,
          duration: _fixtureDuration,
          sampleRate: _fixtureRate,
          channels: _fixtureChannels,
          kbps: kbps,
        );
      });
    }

    testWidgets('identical input and output paths are refused', (_) async {
      final String path = '${dir.path}/same.mp3';
      File(fixture(AudioFormat.mp3)).copySync(path);
      final int before = File(path).lengthSync();
      await expectLater(
        converter.convert(
          inputPath: path,
          outputPath: path,
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        ),
        throwsA(isA<ConversionException>()),
      );
      expect(File(path).lengthSync(), before);
      expect(listing(), <String>['same.mp3']);
    });
  });

  group('sample rate and channels are kept', () {
    for (final (int rate, int channels) in <(int, int)>[
      (44100, 2),
      (48000, 2),
      (16000, 1),
    ]) {
      testWidgets('$rate Hz, $channels ch to every format', (_) async {
        final String input = await writeSampleWav(
          '${dir.path}/in.wav',
          seconds: 1,
          sampleRate: rate,
          channels: channels,
        );
        for (final AudioFormat to in AudioFormat.values) {
          final String output = await converter.convert(
            inputPath: input,
            outputPath: '${dir.path}/out.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to),
          );
          final AudioInfo info = await converter.probe(output);
          expectInfo(
            info,
            format: to,
            duration: _fixtureDuration,
            sampleRate: rate,
            channels: channels,
            kbps: to == AudioFormat.wav ? null : 128,
          );
          File(output).deleteSync();
        }
      });
    }

    testWidgets('wav from a compressed input is 16-bit PCM', (_) async {
      // The probe reports the PCM bitrate, which fixes the bit depth: rate * channels * 16.
      for (final AudioFormat from in <AudioFormat>[
        AudioFormat.mp3,
        AudioFormat.m4a,
        AudioFormat.aac,
        AudioFormat.wma,
      ]) {
        final String output = await converter.convert(
          inputPath: fixture(from),
          outputPath: '${dir.path}/from_${from.name}.wav',
          options: const ConvertOptions(outputFormat: AudioFormat.wav),
        );
        final AudioInfo info = await converter.probe(output);
        expect(
          info.bitrateKbps,
          (_fixtureRate * _fixtureChannels * 16 / 1000).round(),
          reason: from.name,
        );
      }
    });
  });

  group('cancellation', () {
    late String longInput;
    late Directory longDir;

    setUpAll(() async {
      longDir = Directory.systemTemp.createTempSync('su3_long_');
      longInput = await writeSampleWav(
        '${longDir.path}/long.wav',
        seconds: 300,
      );
    });
    tearDownAll(() => longDir.deleteSync(recursive: true));

    for (final AudioFormat to in AudioFormat.values) {
      // WAV output is a straight copy and can finish before a cancel request arrives.
      if (to == AudioFormat.wav) continue;
      testWidgets('cancel while converting to ${to.name} leaves nothing', (
        _,
      ) async {
        final CancelToken token = CancelToken();
        final Future<String> result = converter.convert(
          inputPath: longInput,
          outputPath: '${dir.path}/cancelled.${to.fileExtension}',
          options: ConvertOptions(outputFormat: to, bitrateKbps: 256),
          onProgress: (double progress) {
            if (progress > 0.02) token.cancel();
          },
          cancelToken: token,
        );
        await expectLater(result, throwsA(isA<ConversionCancelledException>()));
        expect(listing(), isEmpty);
      });
    }

    testWidgets('cancel right after starting leaves nothing', (_) async {
      final CancelToken token = CancelToken();
      final Future<String> result = converter.convert(
        inputPath: longInput,
        outputPath: '${dir.path}/early.mp3',
        options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        cancelToken: token,
      );
      token.cancel();
      await expectLater(result, throwsA(isA<ConversionCancelledException>()));
      expect(listing(), isEmpty);
    });

    testWidgets('cancelling after completion changes nothing', (_) async {
      final CancelToken token = CancelToken();
      final String output = await converter.convert(
        inputPath: fixture(AudioFormat.wav),
        outputPath: '${dir.path}/done.mp3',
        options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        cancelToken: token,
      );
      token.cancel();
      expect(File(output).existsSync(), isTrue);
      expect(listing(), <String>['done.mp3']);
    });

    testWidgets('a converter works again after a cancelled job', (_) async {
      final CancelToken token = CancelToken()..cancel();
      await expectLater(
        converter.convert(
          inputPath: longInput,
          outputPath: '${dir.path}/never.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
          cancelToken: token,
        ),
        throwsA(isA<ConversionCancelledException>()),
      );
      final String output = await converter.convert(
        inputPath: fixture(AudioFormat.wav),
        outputPath: '${dir.path}/after.mp3',
        options: const ConvertOptions(outputFormat: AudioFormat.mp3),
      );
      expect((await converter.probe(output)).format, AudioFormat.mp3);
      expect(listing(), <String>['after.mp3']);
    });
  });

  group('error paths', () {
    Uint8List garbage() => Uint8List.fromList(
      List<int>.generate(4096, (int i) => (i * 31) & 0xFF),
    );

    testWidgets('probe of a missing file', (_) async {
      await expectLater(
        converter.probe('${dir.path}/missing.wav'),
        throwsA(
          isA<ConversionException>()
              .having((e) => e.runtimeType, 'type', ConversionException)
              .having((e) => e.nativeErrorCode, 'code', 2),
        ),
      );
    });

    testWidgets('probe of a garbage file', (_) async {
      File('${dir.path}/garbage.wav').writeAsBytesSync(garbage());
      await expectLater(
        converter.probe('${dir.path}/garbage.wav'),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    testWidgets('probe of an empty file', (_) async {
      File('${dir.path}/empty.mp3').writeAsBytesSync(<int>[]);
      await expectLater(
        converter.probe('${dir.path}/empty.mp3'),
        throwsA(isA<ConversionException>()),
      );
    });

    testWidgets('probe of a truncated file does not crash', (_) async {
      final Uint8List bytes = File(fixture(AudioFormat.m4a)).readAsBytesSync();
      File('${dir.path}/cut.m4a').writeAsBytesSync(bytes.sublist(0, 20));
      try {
        await converter.probe('${dir.path}/cut.m4a');
      } on ConversionException {
        // Either an error or a best-effort result is acceptable; a crash is not.
      }
    });

    for (final AudioFormat to in AudioFormat.values) {
      testWidgets('missing input to ${to.name}: typed error, no output', (
        _,
      ) async {
        await expectLater(
          converter.convert(
            inputPath: '${dir.path}/missing.wav',
            outputPath: '${dir.path}/out.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to),
          ),
          throwsA(
            isA<ConversionException>()
                .having((e) => e.runtimeType, 'type', ConversionException)
                .having((e) => e.nativeErrorCode, 'code', 2),
          ),
        );
        expect(listing(), isEmpty);
      });

      testWidgets('garbage input to ${to.name}: typed error, no output', (
        _,
      ) async {
        File('${dir.path}/garbage.wav').writeAsBytesSync(garbage());
        await expectLater(
          converter.convert(
            inputPath: '${dir.path}/garbage.wav',
            outputPath: '${dir.path}/out.${to.fileExtension}',
            options: ConvertOptions(outputFormat: to),
          ),
          throwsA(isA<UnsupportedFormatException>()),
        );
        expect(listing(), <String>['garbage.wav']);
      });
    }

    testWidgets('a truncated input never leaves a partial output', (_) async {
      final Uint8List bytes = File(fixture(AudioFormat.mp3)).readAsBytesSync();
      File(
        '${dir.path}/cut.mp3',
      ).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      try {
        await converter.convert(
          inputPath: '${dir.path}/cut.mp3',
          outputPath: '${dir.path}/out.m4a',
          options: const ConvertOptions(outputFormat: AudioFormat.m4a),
        );
        // A best-effort conversion of the readable half is acceptable and must be complete.
        expect(
          (await converter.probe('${dir.path}/out.m4a')).format,
          AudioFormat.m4a,
        );
      } on ConversionException {
        expect(listing(), <String>['cut.mp3']);
      }
    });

    testWidgets('an unwritable output directory fails without a crash', (
      _,
    ) async {
      await expectLater(
        converter.convert(
          inputPath: fixture(AudioFormat.wav),
          outputPath: '${dir.path}/no_such_dir/out.mp3',
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        ),
        throwsA(isA<ConversionException>()),
      );
      expect(listing(), isEmpty);
    });
  });

  group('the extension lies', () {
    testWidgets('probe detects mp3 content named .wav', (_) async {
      final String path = '${dir.path}/liar.wav';
      File(fixture(AudioFormat.mp3)).copySync(path);
      expect((await converter.probe(path)).format, AudioFormat.mp3);
    });

    testWidgets('every fixture is detected under a wrong extension', (_) async {
      for (final AudioFormat real in AudioFormat.values) {
        final AudioFormat claimed =
            AudioFormat.values[(real.index + 1) % AudioFormat.values.length];
        final String path =
            '${dir.path}/${real.name}_as.${claimed.fileExtension}';
        File(fixture(real)).copySync(path);
        expect(
          (await converter.probe(path)).format,
          real,
          reason: '${real.name} named .${claimed.fileExtension}',
        );
      }
    });

    testWidgets('mp3 content named .wav converts to m4a', (_) async {
      final String path = '${dir.path}/liar.wav';
      File(fixture(AudioFormat.mp3)).copySync(path);
      final String output = await converter.convert(
        inputPath: path,
        outputPath: '${dir.path}/out.m4a',
        options: const ConvertOptions(outputFormat: AudioFormat.m4a),
      );
      expectInfo(
        await converter.probe(output),
        format: AudioFormat.m4a,
        duration: _fixtureDuration,
        sampleRate: _fixtureRate,
        channels: _fixtureChannels,
        kbps: 128,
      );
    });

    testWidgets('the output format follows the options, not the file name', (
      _,
    ) async {
      final String output = await converter.convert(
        inputPath: fixture(AudioFormat.wav),
        outputPath: '${dir.path}/actually_aac.mp3',
        options: const ConvertOptions(outputFormat: AudioFormat.aac),
      );
      expect((await converter.probe(output)).format, AudioFormat.aac);
    });
  });

  group('output file names', () {
    testWidgets('a batch with equal base names gets numbered outputs', (
      _,
    ) async {
      final List<String> outputs = <String>[];
      for (final AudioFormat from in <AudioFormat>[
        AudioFormat.wav,
        AudioFormat.wma,
        AudioFormat.m4a,
      ]) {
        final String target = resolveUniqueOutputPath(
          dir.path,
          'tone',
          AudioFormat.mp3,
          reserved: outputs,
        );
        outputs.add(target);
        await converter.convert(
          inputPath: fixture(from),
          outputPath: target,
          options: const ConvertOptions(outputFormat: AudioFormat.mp3),
        );
      }
      expect(listing(), <String>['tone (1).mp3', 'tone (2).mp3', 'tone.mp3']);
    });
  });
}
