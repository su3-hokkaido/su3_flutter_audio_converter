import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

void main() {
  late Directory dir;
  final String sep = Platform.pathSeparator;

  setUp(() => dir = Directory.systemTemp.createTempSync('su3_path_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String path(String name) => '${dir.path}$sep$name';

  test('uses the plain name when nothing exists', () {
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song.mp3'),
    );
  });

  test('uses the extension of the output format', () {
    for (final AudioFormat format in AudioFormat.values) {
      expect(
        resolveUniqueOutputPath(dir.path, 'a', format),
        path('a.${format.fileExtension}'),
      );
    }
  });

  test('appends (1), then (2), when files exist', () {
    File(path('song.mp3')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song (1).mp3'),
    );
    File(path('song (1).mp3')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song (2).mp3'),
    );
  });

  test('fills the lowest free number', () {
    File(path('song.mp3')).writeAsStringSync('x');
    File(path('song (2).mp3')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song (1).mp3'),
    );
  });

  test('a file with another extension does not collide', () {
    File(path('song.wav')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song.mp3'),
    );
  });

  test('an existing directory counts as taken', () {
    Directory(path('song.mp3')).createSync();
    expect(
      resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3),
      path('song (1).mp3'),
    );
  });

  test('reserved paths count as taken, also within one batch', () {
    final List<String> batch = <String>[];
    for (int i = 0; i < 3; i++) {
      batch.add(
        resolveUniqueOutputPath(
          dir.path,
          'a',
          AudioFormat.mp3,
          reserved: batch,
        ),
      );
    }
    expect(batch, <String>[
      path('a.mp3'),
      path('a (1).mp3'),
      path('a (2).mp3'),
    ]);
  });

  test('reserved paths and existing files combine', () {
    File(path('a.mp3')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath(
        dir.path,
        'a',
        AudioFormat.mp3,
        reserved: <String>[path('a (1).mp3')],
      ),
      path('a (2).mp3'),
    );
  });

  test('reserved paths of another name are ignored', () {
    expect(
      resolveUniqueOutputPath(
        dir.path,
        'a',
        AudioFormat.mp3,
        reserved: <String>[path('b.mp3')],
      ),
      path('a.mp3'),
    );
  });

  test('a trailing separator on the directory gives the same result', () {
    File(path('song.mp3')).writeAsStringSync('x');
    expect(
      resolveUniqueOutputPath('${dir.path}$sep', 'song', AudioFormat.mp3),
      path('song (1).mp3'),
    );
    expect(
      resolveUniqueOutputPath('${dir.path}$sep', 'other', AudioFormat.wav),
      path('other.wav'),
    );
  });

  test('does not create any file', () {
    resolveUniqueOutputPath(dir.path, 'song', AudioFormat.mp3);
    expect(dir.listSync(), isEmpty);
  });
}
