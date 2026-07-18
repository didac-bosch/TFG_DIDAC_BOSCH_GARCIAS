// ===========================================================================
// SAMPLE FLIGHT DATA
// ===========================================================================
// Aquí se definen los modelos de datos y se fabrican los tres vuelos de ejemplo
// que alimentan la demo del Flight Log Viewer.
//
// En el EZDrone real, este fichero se correspondería con las clases
// FlightSession y FlightLog del Provider (provider.dart): allí los datos se van
// acumulando en directo mientras el dron vuela. Aquí, en cambio, se generan de
// forma sintética para tener algo que enseñar sin necesidad de volar.
//
// MODELOS QUE EXPORTA:
//   FlightLog     - foto de la telemetría en un instante concreto
//   FlightSession - un vuelo entero (trayectoria + log + métricas)
//
// DATOS DE EJEMPLO:
//   sampleSessions - tres vuelos sobre el campus de la EETAC (Castelldefels):
//     1. Cuadrado a 20 m   (CLASSIC + SITL, completado,    4 min 32 s)
//     2. Triángulo a 30 m  (IMU,            completado,    6 min 10 s)
//     3. Vuelo parcial 15 m (VOICE + SITL,  interrumpido,  1 min 48 s)
// ===========================================================================

import 'dart:math';
import 'package:latlong2/latlong.dart';

// -------- MODELOS ------------------------------------------------

// Instantánea de telemetría, tomada una vez por segundo durante el vuelo.
// Cada FlightLog es una fila del CSV que se exporta:
//   timestamp | lat | lon | alt_m | speed_ms | bat_pct | heading_deg
class FlightLog {
  final DateTime timestamp;
  final double lat;
  final double lon;
  final double alt;      // altura sobre el punto de despegue, en metros
  final double speed;    // velocidad en m/s
  final double bat;      // batería restante, 0-100 %
  final double heading;  // rumbo en grados, 0-360

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

// Un vuelo completo. Es el equivalente a FlightSession en el Provider de
// EZDrone, donde los campos se van rellenando en directo y se guardan al
// aterrizar.
class FlightSession {
  final DateTime startTime;
  final Duration duration;
  final String controlMode;  // modo de control: 'classic' | 'voice' | 'imu'
  final bool isSitl;         // true si el vuelo fue en el simulador SITL
  final bool completed;      // false si el vuelo se interrumpió a media misión
  final List<LatLng> trail;   // trayectoria: lista de posiciones GPS
  final List<FlightLog> log;  // telemetría: una instantánea por segundo (aprox.)

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

  // Altura máxima que alcanzó el dron (m).
  double get maxAlt   => log.isEmpty ? 0 : log.map((s) => s.alt).reduce(max);

  // Velocidad punta del vuelo (m/s).
  double get maxSpeed => log.isEmpty ? 0 : log.map((s) => s.speed).reduce(max);

  // Nivel de batería más bajo que se llegó a registrar (%).
  double get minBat   => log.isEmpty ? 100 : log.map((s) => s.bat).reduce(min);

  // Desnivel ganado: diferencia entre la altura máxima y la de despegue (m).
  double get altGain {
    if (log.length < 2) return 0;
    return log.map((s) => s.alt).reduce(max) - log.first.alt;
  }

  // Distancia total recorrida, sumando tramo a tramo con Haversine (m).
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

// Lista de sesiones ya montada y lista para pasarle a FlightLogScreen.
// Todas las coordenadas caen sobre el campus de la EETAC.
final List<FlightSession> sampleSessions = _buildSessions();

List<FlightSession> _buildSessions() {
  final rng = Random(42); // semilla fija: así los datos salen siempre iguales

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

  // Se monta cada FlightSession con su trayectoria y su log generado.
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

// Fabrica los snapshots de telemetría de forma coherente con la trayectoria:
//   - la altura sube durante el primer 15 % del vuelo, se mantiene, y baja en
//     el último 15 %
//   - la batería cae de forma lineal a lo largo del vuelo
//   - el heading apunta siempre hacia el siguiente punto de la ruta
List<FlightLog> _genLog(
  DateTime start,
  List<LatLng> coords,
  double targetAlt,
  Random rng,
) {
  final logs = <FlightLog>[];
  final n    = coords.length;

  for (int i = 0; i < n; i++) {
    final t = i / (n - 1); // progreso del vuelo, de 0.0 a 1.0

    // Perfil de altura: rampa de subida, crucero con ruido, rampa de bajada
    final double alt;
    if (t < 0.15) {
      alt = targetAlt * (t / 0.15);
    } else if (t > 0.85) {
      alt = targetAlt * ((1 - t) / 0.15);
    } else {
      alt = targetAlt + rng.nextDouble() * 1.5 - 0.75;
    }

    // Velocidad: lenta al despegar/aterrizar, de crucero en el tramo central
    final speed = (t < 0.1 || t > 0.9)
        ? rng.nextDouble() * 1.5
        : 3.0 + rng.nextDouble() * 2.5;

    // Batería: baja del 95 % restando un 25 % a lo largo del vuelo, con ruido
    final bat = 95.0 - t * 25.0 - rng.nextDouble() * 2;

    // Heading: rumbo hacia el siguiente punto (fórmula del bearing inicial)
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

// Distancia entre dos puntos GPS con la fórmula de Haversine (en metros).
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
