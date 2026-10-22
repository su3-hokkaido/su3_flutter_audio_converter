/// Cancels a running conversion. Create one per conversion, pass it to `AudioConverter.convert`
/// and call [cancel]; the conversion then completes with a `ConversionCancelledException`.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// Requests cancellation. Calling it again, or after the conversion ended, does nothing.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }

  /// Registers [listener] to run on [cancel]; for use by converter implementations.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a listener added with [addListener].
  void removeListener(void Function() listener) => _listeners.remove(listener);
}
