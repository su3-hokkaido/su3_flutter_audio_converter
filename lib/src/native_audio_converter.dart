import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../su3_flutter_audio_converter_bindings_generated.dart';
import 'audio_converter.dart';
import 'audio_format.dart';
import 'cancel_token.dart';
import 'convert_options.dart';
import 'exceptions.dart';
import 'native_library.dart';

// Values of the su3_status and su3_error enums in src/su3_flutter_audio_converter.h.
const int _statusDone = 1;
const int _statusFailed = 2;
const int _statusCancelled = 3;
const int _errUnsupportedFormat = 3;
const int _errCorrupted = 4;
const int _errUnsupportedBitrate = 5;
const int _errCancelled = 7;

const int _errorMessageSize = 512;

/// [AudioConverter] implemented on top of the native core through `dart:ffi`.
class NativeAudioConverter implements AudioConverter {
  NativeAudioConverter();

  @override
  List<int> supportedBitrates(AudioFormat format) => switch (format) {
    AudioFormat.wav => const <int>[],
    // The WMAv2 encoder is not offered at 320 kbps (docs/project_plan.md decision #16).
    AudioFormat.wma => const <int>[128, 192, 256],
    AudioFormat.mp3 ||
    AudioFormat.m4a ||
    AudioFormat.aac => const <int>[128, 192, 256, 320],
  };

  @override
  Future<String> convert({
    required String inputPath,
    required String outputPath,
    required ConvertOptions options,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final AudioFormat format = options.outputFormat;
    final int bitrate = options.effectiveBitrateKbps;
    if (format != AudioFormat.wav &&
        !supportedBitrates(format).contains(bitrate)) {
      throw UnsupportedBitrateException(
        '$bitrate kbps is not supported for ${format.name}; '
        'use one of ${supportedBitrates(format)}',
      );
    }
    if (cancelToken != null && cancelToken.isCancelled) {
      throw const ConversionCancelledException();
    }

    final Su3FlutterAudioConverterBindings bindings = nativeBindings;
    final Completer<String> completer = Completer<String>();
    int jobId = 0;
    void Function()? cancelListener;

    late final NativeCallable<su3_job_callbackFunction> callback;
    void finish() {
      if (cancelListener != null) cancelToken?.removeListener(cancelListener);
      callback.close();
    }

    // Native code reports from its worker thread; the listener delivers the calls to this isolate
    // asynchronously, so `jobId` is always assigned before the first event is handled.
    callback = NativeCallable<su3_job_callbackFunction>.listener((
      int id,
      double progress,
      int status,
      int errorCode,
    ) {
      if (status == _statusDone) {
        try {
          onProgress?.call(1.0);
        } catch (error, stackTrace) {
          bindings.su3_job_release(id);
          finish();
          completer.completeError(error, stackTrace);
          return;
        }
        bindings.su3_job_release(id);
        finish();
        completer.complete(outputPath);
      } else if (status == _statusFailed || status == _statusCancelled) {
        Object? failure;
        StackTrace? failureTrace;
        try {
          failure = _exceptionFor(errorCode, _readErrorMessage(bindings, id));
        } catch (error, stackTrace) {
          failure = error;
          failureTrace = stackTrace;
        }
        try {
          bindings.su3_job_release(id);
        } finally {
          finish();
          completer.completeError(failure, failureTrace);
        }
      } else if (progress >= 0 && onProgress != null) {
        try {
          onProgress(progress > 1.0 ? 1.0 : progress);
        } catch (error, stackTrace) {
          // A throwing progress callback fails the conversion instead of being lost.
          bindings.su3_convert_cancel(id);
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      }
    });

    Pointer<Utf8>? input;
    Pointer<Utf8>? output;
    Pointer<su3_convert_options>? nativeOptions;
    try {
      input = inputPath.toNativeUtf8();
      output = outputPath.toNativeUtf8();
      nativeOptions = calloc<su3_convert_options>();
      nativeOptions.ref.output_format = format.index;
      nativeOptions.ref.bitrate_kbps = bitrate;
      jobId = bindings.su3_convert_start(
        input.cast(),
        output.cast(),
        nativeOptions,
        callback.nativeFunction,
      );
    } catch (_) {
      callback.close();
      rethrow;
    } finally {
      // The native side copies the paths and options.
      if (input != null) calloc.free(input);
      if (output != null) calloc.free(output);
      if (nativeOptions != null) calloc.free(nativeOptions);
    }
    if (jobId <= 0) {
      callback.close();
      throw _exceptionFor(-jobId, 'The conversion could not be started');
    }

    if (cancelToken != null) {
      final int startedJob = jobId;
      cancelListener = () => bindings.su3_convert_cancel(startedJob);
      cancelToken.addListener(cancelListener);
      if (cancelToken.isCancelled) cancelListener();
    }
    return completer.future;
  }
}

String _readErrorMessage(Su3FlutterAudioConverterBindings bindings, int id) {
  final Pointer<Char> buffer = calloc<Char>(_errorMessageSize);
  try {
    bindings.su3_last_error(id, buffer, _errorMessageSize);
    final int length = buffer.cast<Utf8>().length;
    return utf8.decode(
      buffer.cast<Uint8>().asTypedList(length),
      allowMalformed: true,
    );
  } finally {
    calloc.free(buffer);
  }
}

ConversionException _exceptionFor(int code, String message) {
  return switch (code) {
    _errUnsupportedFormat => UnsupportedFormatException(
      message,
      nativeErrorCode: code,
    ),
    _errCorrupted => CorruptedFileException(message, nativeErrorCode: code),
    _errUnsupportedBitrate => UnsupportedBitrateException(
      message,
      nativeErrorCode: code,
    ),
    _errCancelled =>
      message.isEmpty
          ? const ConversionCancelledException()
          : ConversionCancelledException(message),
    _ => ConversionException(message, nativeErrorCode: code),
  };
}
