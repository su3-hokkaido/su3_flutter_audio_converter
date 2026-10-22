import 'package:flutter_test/flutter_test.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

void main() {
  test('AudioFormat covers exactly the five initial formats', () {
    expect(AudioFormat.values.map((format) => format.name), <String>[
      'mp3',
      'm4a',
      'wma',
      'wav',
      'aac',
    ]);
  });

  test('AudioFormat file extensions have no leading dot', () {
    for (final AudioFormat format in AudioFormat.values) {
      expect(format.fileExtension, format.name);
      expect(format.fileExtension.startsWith('.'), isFalse);
    }
  });
}
