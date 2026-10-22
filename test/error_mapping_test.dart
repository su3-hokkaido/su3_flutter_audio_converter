import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:su3_flutter_audio_converter/src/native_audio_converter.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

void main() {
  group('native error code to exception', () {
    test('3 is UnsupportedFormatException', () {
      final ConversionException e = exceptionForNativeError(3, 'no audio');
      expect(e, isA<UnsupportedFormatException>());
      expect(e.message, 'no audio');
      expect(e.nativeErrorCode, 3);
    });

    test('4 is CorruptedFileException', () {
      final ConversionException e = exceptionForNativeError(4, 'bad data');
      expect(e, isA<CorruptedFileException>());
      expect(e.nativeErrorCode, 4);
    });

    test('5 is UnsupportedBitrateException', () {
      final ConversionException e = exceptionForNativeError(5, 'rate');
      expect(e, isA<UnsupportedBitrateException>());
      expect(e.nativeErrorCode, 5);
    });

    test('7 is ConversionCancelledException with the native message', () {
      final ConversionException e = exceptionForNativeError(7, 'stopped');
      expect(e, isA<ConversionCancelledException>());
      expect(e.message, 'stopped');
      expect(e.nativeErrorCode, 7);
    });

    test('7 with an empty message uses the default message', () {
      final ConversionException e = exceptionForNativeError(7, '');
      expect(e, isA<ConversionCancelledException>());
      expect(e.message, 'Cancelled');
      expect(e.nativeErrorCode, 7);
    });

    test('other codes are the plain ConversionException', () {
      for (final int code in <int>[1, 2, 6, 8, 9, 0, 42, -1]) {
        final ConversionException e = exceptionForNativeError(code, 'm');
        expect(e.runtimeType, ConversionException, reason: 'code $code');
        expect(e.nativeErrorCode, code);
        expect(e.message, 'm');
      }
    });
  });

  group('AudioFormat versus the native su3_format enum', () {
    // Parse the header so a change on either side is caught.
    final Map<String, int> native = <String, int>{};
    final String header = File(
      'src/su3_flutter_audio_converter.h',
    ).readAsStringSync();
    final RegExp entry = RegExp(r'SU3_FORMAT_([A-Z0-9]+)\s*=\s*(\d+)');
    for (final RegExpMatch m in entry.allMatches(header)) {
      native[m.group(1)!.toLowerCase()] = int.parse(m.group(2)!);
    }

    test('the header declares the five formats', () {
      expect(
        native.keys,
        unorderedEquals(<String>['mp3', 'm4a', 'wma', 'wav', 'aac']),
      );
    });

    test('indexes are mp3=0, m4a=1, wma=2, wav=3, aac=4', () {
      expect(AudioFormat.mp3.index, 0);
      expect(AudioFormat.m4a.index, 1);
      expect(AudioFormat.wma.index, 2);
      expect(AudioFormat.wav.index, 3);
      expect(AudioFormat.aac.index, 4);
    });

    test('every AudioFormat index equals the header value', () {
      for (final AudioFormat format in AudioFormat.values) {
        expect(native[format.name], format.index, reason: format.name);
      }
    });
  });
}
