/// Audio formats supported for both input and output (docs/project_plan.md section 3.1).
///
/// A future format (for example 3GP) only needs a new value here plus the native mapping.
enum AudioFormat {
  mp3('mp3'),
  m4a('m4a'),
  wma('wma'),
  wav('wav'),
  aac('aac');

  const AudioFormat(this.fileExtension);

  /// File extension without the leading dot, used to build output file names.
  final String fileExtension;
}
