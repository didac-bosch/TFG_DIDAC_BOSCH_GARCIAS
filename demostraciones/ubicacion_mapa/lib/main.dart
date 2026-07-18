import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

// ============================================================
// DEMO: MAPA CON UBICACIÓN EN TIEMPO REAL
// ============================================================
//
// Esta app demuestra el uso de las librerías geolocator y
// flutter_map para mostrar la ubicación del dispositivo en
// tiempo real sobre un mapa de OpenStreetMap.
//
// LIBRERÍAS:
//   - geolocator: ^14.0.2 - obtiene la posición GPS
//   - flutter_map: ^8.2.2  - renderiza el mapa (sin API key)
//   - latlong2: ^0.9.1    - manejo de coordenadas lat/lng
//
// PERMISOS NECESARIOS:
//   Android - android/app/src/main/AndroidManifest.xml
//     Añadir dentro de <manifest> y fuera de <application>:
//     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//     <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//
//   iOS - ios/Runner/Info.plist
//     Añadir dentro de <dict> al final antes de </dict>:
//     <key>NSLocationWhenInUseUsageDescription</key>
//     <string>Necesitamos tu ubicación para mostrarte en el mapa</string>
//     <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
//     <string>Necesitamos tu ubicación para mostrarte en el mapa</string>
//
// FUNCIONAMIENTO:
//   - Al iniciarse pide permiso de ubicación al usuario
//   - Abre un stream GPS que emite posición cada 1 metro
//   - La primera posición siempre se acepta (para salir del spinner)
//   - Las siguientes se filtran: se ignoran si el error > 50m
//   - Un badge muestra la precisión GPS en tiempo real:
//      Verde  - precisión < 5m  (GPS perfecto)
//      Naranja - precisión < 20m (aceptable)
//      Rojo   - precisión > 20m  (lectura ignorada)
//
// USO EN EL FUTURO:
//   Sustituir _currentPosition por las coordenadas del dron
//   para mostrar su posición en tiempo real en la app principal.
// ============================================================


void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ubicación mapa',
      theme: ThemeData.dark(),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {

  // variables de estado
  LatLng? _currentPosition; // posición actual (null hasta tener GPS)
  double _accuracy = 0;
  final MapController _mapController = MapController(); // controlador del mapa

  @override
  void initState() {
    // se llama automáticamente cuando el widget se crea
    super.initState();
    _startTracking(); // arranca el GPS nada más crear la pantalla
  }

  // abre un stream GPS que emite posición cada 1 metro
  Future<void> _startTracking() async {
    LocationPermission permission =
        await Geolocator.requestPermission(); // pide permiso de ubi al usuario
    if (permission == LocationPermission.denied) return;

    Geolocator.getPositionStream(
      // abre un canal que emite un nuevo valor de posición cada vez que se detecta un cambio de ubicación
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1, // actualiza cada metro
      ),
    ).listen((Position pos) {
      // actualizar precisión siempre (para que se vea en pantalla)
      setState(() => _accuracy = pos.accuracy);

      // primera posición: aceptar siempre para salir del spinner
      // siguientes: ignorar si el margen de error es mayor a 50m
      if (_currentPosition != null && pos.accuracy > 50) return;

      final newPos = LatLng(pos.latitude, pos.longitude);
      setState(() => _currentPosition = newPos); // redibuja la pantalla con la nueva posición
      _mapController.move(newPos, 17); // centra el mapa en la nueva ubicación con zoom 17
    });
  }

  // color del indicador según la precisión
  Color _accuracyColor() {
    if (_accuracy <= 5) return Colors.green;
    if (_accuracy <= 20) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ubicación en tiempo real')),

      // si no hay posición aún, mostrar un spinner de espera
      body: _currentPosition == null
          ? const Center(child: CircularProgressIndicator()) // mientras espera el primer GPS
          : Stack(
              children: [
                FlutterMap( // librería con mapa para flutter
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentPosition!, // posición y zoom iniciales
                    initialZoom: 17,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.app',
                    ),
                    MarkerLayer( 
                      markers: [
                        Marker( // marcador de ubicación (icono modificable)
                          point: _currentPosition!,
                          width: 50,
                          height: 50,
                          child: const Icon(
                            Icons.navigation,
                            color: Colors.blue,
                            size: 40,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // widget para mostrar la precisión GPS
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.gps_fixed,
                          color: _accuracyColor(),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'ACCURACY: ${_accuracy.toStringAsFixed(1)} m',
                          style: TextStyle(
                            color: _accuracyColor(),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
