// ===========================================================================
// SAMPLE FLIGHT DATA 
// ===========================================================================
// Este fichero define los modelos de datos y genera los tres vuelos de ejemplo
// que usa la demo del Flight Log Viewer.
//
// En EZDrone real este fichero equivale a las clases FlightSession y FlightLog
// del Provider (provider.dart), donde los datos se acumulan en tiempo real
// durante el vuelo. Aquí los datos se generan sintéticamente para la demo.
//
// Modelos exportados:
//   • FlightLog     — snapshot de telemetría de un instante concreto
//   • FlightSession — sesión de vuelo completa (trayectoria + log + métricas)
//
// Datos de ejemplo:
//   • sampleSessions — lista con 3 vuelos sobre el campus EETAC (Castelldefels)
//       1. Vuelo cuadrado a 20 m  (CLASSIC + SITL, completado,   4 min 32 s)
//       2. Vuelo triangular a 30 m (IMU,           completado,   6 min 10 s)
//       3. Vuelo parcial a 15 m   (VOICE + SITL,  interrumpido, 1 min 48 s)
// ===========================================================================

import 'dart:math';
import 'package:latlong2/latlong.dart';

// -------- MODELOS ------------------------------------------------

// Snapshot de telemetría grabado una vez por segundo durante el vuelo.

// Columnas del CSV exportado:
//   timestamp | lat | lon | alt_m | speed_ms | bat_pct | heading_deg
class FlightLog {
  final DateTime timestamp;
  final double lat;
  final double lon;
  final double alt;      // metros sobre el punto de despegue
  final double speed;    // m/s
  final double bat;      // porcentaje 0–100
  final double heading;  // grados 0–360

  const FlightLog({
    required this.timestamp,
    required this.lat,
    required this.lon,
    required this.alt,
    required this.speed,
    required this.bat,
    required this.heading,
  });
}

// Sesión de vuelo completa.
// Equivale a FlightSession en el Provider de EZDrone, donde los campos
// se rellenan en tiempo real durante el vuelo y se guardan al aterrizar.
class FlightSession {
  final DateTime startTime;
  final Duration duration;
  final String controlMode;  // 'classic' | 'voice' | 'imu'
  final bool isSitl;
  final bool completed;
  final List<LatLng> trail;   // posiciones GPS de la trayectoria
  final List<FlightLog> log;  // snapshots de telemetría (1 por segundo aprox.)

  const FlightSession({
    required this.startTime,
    required this.duration,
    required this.controlMode,
    required this.isSitl,
    required this.completed,
    required this.trail,
    required this.log,
  });

  // -------- Métricas calculadas -----------------------------------------------

  // Altitud máxima alcanzada durante el vuelo (m).
  double get maxAlt   => log.isEmpty ? 0 : log.map((s) => s.alt).reduce(max);

  // Velocidad máxima registrada (m/s).
  double get maxSpeed => log.isEmpty ? 0 : log.map((s) => s.speed).reduce(max);

  // Batería mínima registrada (%).
  double get minBat   => log.isEmpty ? 100 : log.map((s) => s.bat).reduce(min);

  // Desnivel: diferencia entre la altitud máxima y la altitud de despegue (m).
  double get altGain {
    if (log.length < 2) return 0;
    return log.map((s) => s.alt).reduce(max) - log.first.alt;
  }

  // Distancia total recorrida calculada con la fórmula de Haversine (m).
  double get totalDistanceM {
    if (trail.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < trail.length; i++) {
      d += _haversineM(trail[i - 1], trail[i]);
    }
    return d;
  }
}

// -------- DATOS DE EJEMPLO --------------------------------------------

// Lista de sesiones de ejemplo lista para pasarle a FlightLogScreen.
// Coordenadas centradas en el campus EETAC
final List<FlightSession> sampleSessions = _buildSessions();

List<FlightSession> _buildSessions() {
  final rng = Random(42); // semilla fija, datos reproducibles

  // --------- Sesión 1: cuadrado a 20 m — CLASSIC + SITL — completado 
  final coords1 = const [
    LatLng(41.27450, 1.98800), // despegue
    LatLng(41.27465, 1.98800),
    LatLng(41.27480, 1.98800),
    LatLng(41.27495, 1.98810),
    LatLng(41.27510, 1.98825), // lado norte
    LatLng(41.27525, 1.98840),
    LatLng(41.27540, 1.98855),
    LatLng(41.27555, 1.98870),
    LatLng(41.27555, 1.98890), // lado este
    LatLng(41.27555, 1.98910),
    LatLng(41.27555, 1.98930),
    LatLng(41.27555, 1.98950),
    LatLng(41.27540, 1.98950), // lado sur
    LatLng(41.27525, 1.98950),
    LatLng(41.27510, 1.98950),
    LatLng(41.27495, 1.98940),
    LatLng(41.27480, 1.98930), // retorno oeste
    LatLng(41.27465, 1.98920),
    LatLng(41.27450, 1.98910),
    LatLng(41.27450, 1.98890),
    LatLng(41.27450, 1.98870),
    LatLng(41.27450, 1.98850),
    LatLng(41.27450, 1.98820),
    LatLng(41.27450, 1.98800), // aterrizaje
  ];

  // ------ Sesión 2: triángulo a 30 m — IMU — completado
  final coords2 = const [
    LatLng(41.27450, 1.98800),
    LatLng(41.27480, 1.98820),
    LatLng(41.27510, 1.98840),
    LatLng(41.27530, 1.98860),
    LatLng(41.27545, 1.98900),
    LatLng(41.27545, 1.98940),
    LatLng(41.27525, 1.98960),
    LatLng(41.27500, 1.98955),
    LatLng(41.27475, 1.98940),
    LatLng(41.27455, 1.98910),
    LatLng(41.27450, 1.98870),
    LatLng(41.27450, 1.98835),
    LatLng(41.27450, 1.98800),
  ];

  // ------ Sesión 3: vuelo parcial a 15 m — VOICE + SITL — interrumpido
  final coords3 = const [
    LatLng(41.27450, 1.98800),
    LatLng(41.27465, 1.98815),
    LatLng(41.27480, 1.98830),
    LatLng(41.27490, 1.98845),
    LatLng(41.27495, 1.98860),
    LatLng(41.27490, 1.98875),
  ];

  // FlightSession con datos generados a partir de las coordenadas.
  return [
    FlightSession(
      startTime:   DateTime(2026, 4, 10, 10, 15),
      duration:    const Duration(minutes: 4, seconds: 32),
      controlMode: 'classic',
      isSitl:      true,
      completed:   true,
      trail:       coords1,
      log:         _genLog(DateTime(2026, 4, 10, 10, 15), coords1, 20.0, rng),
    ),
    FlightSession(
      startTime:   DateTime(2026, 4, 12, 16, 42),
      duration:    const Duration(minutes: 6, seconds: 10),
      controlMode: 'imu',
      isSitl:      false,
      completed:   true,
      trail:       coords2,
      log:         _genLog(DateTime(2026, 4, 12, 16, 42), coords2, 30.0, rng),
    ),
    FlightSession(
      startTime:   DateTime(2026, 4, 15, 9, 5),
      duration:    const Duration(minutes: 1, seconds: 48),
      controlMode: 'voice',
      isSitl:      true,
      completed:   false,
      trail:       coords3,
      log:         _genLog(DateTime(2026, 4, 15, 9, 5), coords3, 15.0, rng),
    ),
  ];
}

// ------- HELPERS ----------------------------------------------

// Genera snapshots de telemetría coherentes con la trayectoria.
// La altitud sube en el primer 15 % del vuelo, se mantiene y baja en el.  último 15 %. 
// La batería decae linealmente. El heading apunta al siguiente punto de la trayectoria.

List<FlightLog> _genLog(
  DateTime start,
  List<LatLng> coords,
  double targetAlt,
  Random rng,
) {
  final logs = <FlightLog>[];
  final n    = coords.length;

  for (int i = 0; i < n; i++) {
    final t = i / (n - 1);

    final double alt;
    if (t < 0.15) {
      alt = targetAlt * (t / 0.15);
    } else if (t > 0.85) {
      alt = targetAlt * ((1 - t) / 0.15);
    } else {
      alt = targetAlt + rng.nextDouble() * 1.5 - 0.75;
    }

    final speed = (t < 0.1 || t > 0.9)
        ? rng.nextDouble() * 1.5
        : 3.0 + rng.nextDouble() * 2.5;

    final bat = 95.0 - t * 25.0 - rng.nextDouble() * 2;

    double heading = 0;
    if (i < n - 1) {
      final from = coords[i];
      final to   = coords[i + 1];
      final dLon = (to.longitude - from.longitude) * pi / 180;
      final lat1 = from.latitude * pi / 180;
      final lat2 = to.latitude   * pi / 180;
      final y = sin(dLon) * cos(lat2);
      final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
      heading = (atan2(y, x) * 180 / pi + 360) % 360;
    }

    logs.add(FlightLog(
      timestamp: start.add(Duration(
        seconds: (i * (300 / n.clamp(1, 9999))).round(),
      )),
      lat:     coords[i].latitude,
      lon:     coords[i].longitude,
      alt:     alt.clamp(0, 200),
      speed:   speed,
      bat:     bat,
      heading: heading,
    ));
  }
  return logs;
}

// Distancia entre dos puntos GPS usando la fórmula de Haversine (metros).
double _haversineM(LatLng a, LatLng b) {
  const r    = 6371000.0;
  final dLat = (b.latitude  - a.latitude)  * pi / 180;
  final dLon = (b.longitude - a.longitude) * pi / 180;
  final sinDLat = sin(dLat / 2);
  final sinDLon = sin(dLon / 2);
  final h = sinDLat * sinDLat +
      cos(a.latitude * pi / 180) * cos(b.latitude * pi / 180) *
      sinDLon * sinDLon;
  return 2 * r * asin(sqrt(h));
}