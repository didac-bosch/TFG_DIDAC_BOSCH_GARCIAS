// ===========================================================================
// MAIN — Flight Log Demo
// ===========================================================================
// Punto de entrada de la demo del historial de vuelos. Monta la app con tema
// oscuro y abre FlightLogScreen, que muestra la lista de sesiones grabadas y
// el detalle de cada vuelo (mapa, slider temporal y descarga CSV).
// Ver flight_log_screen.dart.
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
      // Tema oscuro con el morado corporativo de EZDrone como color primario
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0F),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF7928CA)),
      ),
      home: const FlightLogScreen(),
    );
  }
}
