// ===========================================================================
// MAIN — Flight Log Demo
// ===========================================================================

import 'package:flutter/material.dart';
import 'flight_log_screen.dart';

void main() => runApp(const FlightLogDemoApp());

class FlightLogDemoApp extends StatelessWidget {
  const FlightLogDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flight Log Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0F),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF7928CA)),
      ),
      home: const FlightLogScreen(),
    );
  }
}