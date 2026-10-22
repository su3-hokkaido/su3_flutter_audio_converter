import 'dart:ffi';
import 'dart:io';

import '../su3_flutter_audio_converter_bindings_generated.dart';

const String _libName = 'su3_flutter_audio_converter';

/// The native conversion core (src/), loaded on first use.
final Su3FlutterAudioConverterBindings nativeBindings =
    Su3FlutterAudioConverterBindings(_open());

DynamicLibrary _open() {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}
