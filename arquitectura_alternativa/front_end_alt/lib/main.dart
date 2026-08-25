import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'provider.dart';
import 'screens/setup_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Punto de entrada de EZDrone. Hace tres cosas y nada más: crear el
// DronProvider, dejarlo accesible desde toda la app y abrir SetupScreen.
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Deja visibles las barras del sistema. Las pantallas de vuelo piden pantalla
  // completa por su cuenta (requestFullscreenEZ) cuando hace falta.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
  );

  runApp(
    // Un único DronProvider por encima de todo el árbol: cualquier pantalla
    // accede al MISMO objeto de estado, sin ir pasando datos de una a otra.
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DronProvider()),
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'EZDrone',
        home: SetupScreen(),
      ),
    ),
  );
}