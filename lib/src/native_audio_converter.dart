import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../su3_flutter_audio_converter_bindings_generated.dart';
import 'audio_converter.dart';
import 'audio_format.dart';
import 'audio_info.dart';
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

const List<int> _allBitrates = <int>[128, 192, 256, 320];

/// MP3 below 32 kHz uses MPEG-2 / 2.5 Layer III, which tops out at 160 kbps (64 kbps at 12 kHz and
/// below), so 192 kbps and up are silently capped by the encoder. Only 128 is offered there; at
/// 12 kHz and below the encoder still writes 64 kbps (measured in M5, docs design notes).
List<int> _mp3Bitrates(int? inputSampleRate) =>
    inputSampleRate != null && inputSampleRate < 32000
    ? const <int>[128]
    : _allBitrates;

/// [AudioConverter] implemented on top of the native core through `dart:ffi`.
class NativeAudioConverter implements AudioConverter {
  NativeAudioConverter();

  @override
  List<int> supportedBitrates(AudioFormat format, {AudioInfo? input}) {
    return switch (format) {
      AudioFormat.wav => const <int>[],
      // The WMAv2 encoder is not offered at 320 kbps (docs/project_plan.md decision #16).
      AudioFormat.wma => const <int>[128, 192, 256],
      AudioFormat.mp3 => _mp3Bitrates(input?.sampleRate),
      AudioFormat.m4a || AudioFormat.aac => _allBitrates,
    };
  }

  @override
  Future<AudioInfo> probe(String inputPath) async {
    // su3_probe opens the file and reads stream info synchronously, which can be slow for damaged
    // files or slow storage, so it runs on a short-lived isolate (it loads its own bindings).
    final _ProbeResult result = await Isolate.run(
      () => _probeNative(inputPath),
    );
    if (result.code != 0) {
      throw _exceptionFor(
        result.code,
        'The file could not be read: $inputPath',
      );
    }
    final bool known =
        result.format >= 0 && result.format < AudioFormat.values.length;
    if (!known) {
      throw UnsupportedFormatException(
        'The audio format is not supported: $inputPath',
        nativeErrorCode: _errUnsupportedFormat,
      );
    }
    return AudioInfo(
      format: AudioFormat.values[result.format],
      duration: result.durationMs < 0
          ? null
          : Duration(milliseconds: result.durationMs),
      sampleRate: result.sampleRate > 0 ? result.sampleRate : null,
      channels: result.channels > 0 ? result.channels : null,
      bitrateKbps: result.bitrateBps < 0
          ? null
          : (result.bitrateBps / 1000).round(),
    );
  }

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
    if (format == AudioFormat.mp3 && bitrate != _allBitrates.first) {
      // Rates below 32 kHz limit the MP3 bitrate; the input has to be probed to know.
      final AudioInfo info = await probe(inputPath);
      if (!supportedBitrates(format, input: info).contains(bitrate)) {
        throw UnsupportedBitrateException(
          '$bitrate kbps is not supported for mp3 at ${info.sampleRate} Hz; '
          'use one of ${supportedBitrates(format, input: info)}',
        );
      }
      if (cancelToken != null && cancelToken.isCancelled) {
        throw const ConversionCancelledException();
      }
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
        // A progress callback that threw earlier has already completed the future with its error.
        try {
          onProgress?.call(1.0);
        } catch (error, stackTrace) {
          bindings.su3_job_release(id);
          finish();
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
          return;
        }
        bindings.su3_job_release(id);
        finish();
        if (!completer.isCompleted) completer.complete(outputPath);
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
          if (!completer.isCompleted) {
            completer.completeError(failure, failureTrace);
          }
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
      input = inputPath.toNativeUtf8(allocator: calloc);
      output = outputPath.toNativeUtf8(allocator: calloc);
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

class _ProbeResult {
  const _ProbeResult(
    this.code,
    this.format,
    this.durationMs,
    this.sampleRate,
    this.channels,
    this.bitrateBps,
  );

  final int code;
  final int format;
  final int durationMs;
  final int sampleRate;
  final int channels;
  final int bitrateBps;
}

_ProbeResult _probeNative(String inputPath) {
  final Pointer<Utf8> path = inputPath.toNativeUtf8(allocator: calloc);
  final Pointer<su3_audio_info> info = calloc<su3_audio_info>();
  try {
    final int code = nativeBindings.su3_probe(path.cast(), info);
    final su3_audio_info ref = info.ref;
    return _ProbeResult(
      code,
      ref.format,
      ref.duration_ms,
      ref.sample_rate,
      ref.channels,
      ref.bitrate_bps,
    );
  } finally {
    calloc.free(path);
    calloc.free(info);
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

/// Test access to the mapping of native error codes to exceptions.
@visibleForTesting
ConversionException exceptionForNativeError(int code, String message) =>
    _exceptionFor(code, message);
