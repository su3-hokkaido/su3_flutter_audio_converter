import 'audio_format.dart';
import 'cancel_token.dart';
import 'convert_options.dart';
import 'native_audio_converter.dart';

/// Converts audio files on the device. All work runs on a native worker thread.
abstract interface class AudioConverter {
  /// The converter backed by the bundled FFmpeg.
  factory AudioConverter() = NativeAudioConverter;

  /// Converts [inputPath] to [outputPath] and returns the path actually written.
  ///
  /// [onProgress] receives values from 0.0 to 1.0 on the calling isolate. When [cancelToken] is
  /// cancelled the future fails with `ConversionCancelledException` and the partial output is
  /// removed. Other failures are `ConversionException` subclasses.
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    required ConvertOptions options,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  });

  /// Selectable bitrates for [format] in kbps (empty for WAV).
  List<int> supportedBitrates(AudioFormat format);
}
