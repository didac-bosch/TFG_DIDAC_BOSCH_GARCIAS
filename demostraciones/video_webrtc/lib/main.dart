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
      theme: ThemeData.dark(),
      home: const VideoScreen(),
    );
  }
}
