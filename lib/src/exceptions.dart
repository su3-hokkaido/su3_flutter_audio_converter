/// Base class of every error thrown by the converter.
class ConversionException implements Exception {
  const ConversionException(this.message, {this.nativeErrorCode});

  /// Human readable description, in English.
  final String message;

  /// The `su3_error` code reported by the native core, if the error came from there.
  final int? nativeErrorCode;

  @override
  String toString() => '$runtimeType: $message';
}

/// The input or output format is not supported, or the input has no audio stream.
class UnsupportedFormatException extends ConversionException {
  const UnsupportedFormatException(super.message, {super.nativeErrorCode});
}

/// The bitrate is not offered for the output format (or is rejected by the encoder).
class UnsupportedBitrateException extends ConversionException {
  const UnsupportedBitrateException(super.message, {super.nativeErrorCode});
}

/// The input data could not be read or decoded.
class CorruptedFileException extends ConversionException {
  const CorruptedFileException(super.message, {super.nativeErrorCode});
}

/// The conversion was cancelled through a [CancelToken]. No output file is left behind.
class ConversionCancelledException extends ConversionException {
  const ConversionCancelledException([super.message = 'Cancelled'])
    : super(nativeErrorCode: 7);
}
