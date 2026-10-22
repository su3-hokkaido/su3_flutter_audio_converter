import 'dart:io';

import 'package:flutter/material.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

import 'sample_wav.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: ConvertPage());
  }
}

/// Generates a sample WAV file in the temporary directory and converts it to MP3, so the whole
/// path (Dart, dart:ffi, native worker thread, FFmpeg) can be exercised without a file picker.
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key});

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final AudioConverter _converter = AudioConverter();
  int _bitrate = ConvertOptions.defaultBitrateKbps;
  double _progress = 0;
  CancelToken? _token;
  String _status = 'Idle';

  Future<void> _run() async {
    final CancelToken token = CancelToken();
    setState(() {
      _token = token;
      _progress = 0;
      _status = 'Generating a 3 minute sample WAV...';
    });
    final Directory dir = Directory.systemTemp.createTempSync('su3_example_');
    try {
      final String input = await writeSampleWav(
        '${dir.path}/sample.wav',
        seconds: 180,
      );
      if (!mounted) return;
      setState(() => _status = 'Converting...');
      final Stopwatch watch = Stopwatch()..start();
      final String output = await _converter.convert(
        inputPath: input,
        outputPath: '${dir.path}/sample.mp3',
        options: ConvertOptions(
          outputFormat: AudioFormat.mp3,
          bitrateKbps: _bitrate,
        ),
        onProgress: (double progress) {
          if (mounted) setState(() => _progress = progress);
        },
        cancelToken: token,
      );
      final int bytes = File(output).lengthSync();
      if (!mounted) return;
      setState(
        () => _status =
            'Done in ${watch.elapsedMilliseconds} ms: $bytes bytes\n$output',
      );
    } on Object catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      dir.deleteSync(recursive: true);
      if (mounted) setState(() => _token = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool running = _token != null;
    return Scaffold(
      appBar: AppBar(title: const Text('su3_flutter_audio_converter')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DropdownButton<int>(
              value: _bitrate,
              items: <DropdownMenuItem<int>>[
                for (final int kbps in _converter.supportedBitrates(
                  AudioFormat.mp3,
                ))
                  DropdownMenuItem<int>(value: kbps, child: Text('$kbps kbps')),
              ],
              onChanged: running
                  ? null
                  : (int? value) => setState(() => _bitrate = value ?? 128),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                FilledButton(
                  onPressed: running ? null : _run,
                  child: const Text('Convert sample WAV to MP3'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: running ? () => _token?.cancel() : null,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
