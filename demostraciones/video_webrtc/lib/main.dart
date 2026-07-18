// ===========================================================================
// MAIN — WebRTC Demo
// ===========================================================================
// Punto de entrada de la demo de vídeo WebRTC. Solo monta la app y lanza
// VideoScreen, que es donde vive toda la lógica (conexión WebRTC, detección
// YOLO, captura y grabación). Ver video_screen.dart.
// ===========================================================================

import 'package:flutter/material.dart';
import 'video_screen.dart';

void main() {
  runApp(const WebRTCDemoApp());
}

class WebRTCDemoApp extends StatelessWidget {
  const WebRTCDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC Demo',
      theme: ThemeData.dark(),          // tema oscuro para que el vídeo destaque
      home: const VideoScreen(),
    );
  }
}
