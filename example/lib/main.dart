import 'package:flutter/material.dart';
import 'package:su3_flutter_audio_converter/su3_flutter_audio_converter.dart';

// Placeholder until the converter API lands (docs/2026-10-22_01_step1-package-scaffold, M3).
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('su3_flutter_audio_converter')),
        body: Center(
          child: Text(
            'Formats: ${AudioFormat.values.map((f) => f.name).join(', ')}',
          ),
        ),
      ),
    );
  }
}
