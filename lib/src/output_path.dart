import 'dart:io';

import 'audio_format.dart';

/// Returns a path in [directory] named "[baseName].[extension of format]" that does not exist yet.
///
/// When the name is taken a number is appended: `recording.mp3`, `recording (1).mp3`,
/// `recording (2).mp3`, ... (docs/project_plan.md section 3.5). Paths in [reserved] count as taken,
/// so several outputs of one batch with the same name get different numbers even before the files
/// are written. [baseName] is the input file name without its extension.
String resolveUniqueOutputPath(
  String directory,
  String baseName,
  AudioFormat format, {
  Iterable<String> reserved = const <String>[],
}) {
  // macOS and Windows file systems are case-insensitive by default, so compare lower-cased names
  // there to catch `Tone.mp3` against `tone.mp3`.
  final bool foldCase = Platform.isMacOS || Platform.isWindows;
  String key(String path) => foldCase ? path.toLowerCase() : path;
  final Set<String> taken = reserved.map(key).toSet();
  final String separator = Platform.pathSeparator;
  final String prefix = directory.endsWith(separator)
      ? directory
      : '$directory$separator';
  final String extension = format.fileExtension;

  String candidate = '$prefix$baseName.$extension';
  int number = 0;
  while (taken.contains(key(candidate)) ||
      FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
    number++;
    candidate = '$prefix$baseName ($number).$extension';
  }
  return candidate;
}
