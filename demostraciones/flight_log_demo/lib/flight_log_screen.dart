// ===========================================================================
// FLIGHT LOG SCREEN 
// ===========================================================================
// Pantalla de historial de vuelos. Muestra la lista de sesiones grabadas
// y permite explorar el detalle de cada una: mapa de trayectoria, slider
// temporal y descarga del log en CSV.
//
// Este fichero contiene únicamente la capa de presentación (UI). Los datos
// que muestra proceden de sample_flight_data.dart, que expone la lista
// sampleSessions. En EZDrone real los datos equivalentes se leen del
// Provider (provider.flightHistory) y se acumulan en tiempo real durante
// el vuelo.
//
// Estructura de este fichero:
//   • AppColors              — paleta de colores idéntica a EZDrone
//   • FlightLogScreen        — lista principal de sesiones
//   • _SessionCard           — tarjeta de resumen de una sesión
//   • _MetricTile            — tile de métrica (icono + valor + etiqueta)
//   • _FlightDetailSheet     — bottom sheet con mapa, slider y estadísticas
//   • _StatCard              — tarjeta de estadística en el detail sheet
//   • Helpers                — _modeColor, _formatDuration, _formatDistance,
//                              _formatDate
// ===========================================================================

import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'sample_flight_data.dart';

// -----COLORES -------------------------------
class AppColors {
  static const background = Color(0xFF0D0D0F);
  static const surface = Color(0xFF1A1A1F);
  static const primary = Color(0xFF7928CA);
  static const danger = Color(0xFFFF4444);
  static const warning = Color(0xFFFFA500);
  static const disabled = Color(0xFF2E2E35);
  static const textPrimary = Color(0xFFEEEEEE);
  static const textSecondary = Color(0xFF888899);
}

// ------ PANTALLA PRINCIPAL --------------------------
/// Muestra la lista de sesiones de vuelo. Cada sesión se muestra en una tarjeta con sus métricas principales, y al pulsar se abre un bottom sheet con el detalle completo del vuelo.

class FlightLogScreen extends StatelessWidget {
  const FlightLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // En EZDrone: final sessions = context.watch<DronProvider>().flightHistory;
    final sessions = sampleSessions;

    final screenH = MediaQuery.of(context).size.height;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'FLIGHT LOG',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
        actions: [
          // Badge con número de sesiones
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${sessions.length}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),

      // Lista de sesiones
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: sessions.length,
        itemBuilder: (ctx, i) => _SessionCard(session: sessions[i]),
      ),
    );
  }
}

// ------ TARJETA DE SESIÓN --------------------------
// Muestra un resumen de la sesión con sus métricas principales. Al pulsar, abre el bottom sheet con el detalle completo del vuelo.

class _SessionCard extends StatelessWidget {
  final FlightSession session;
  const _SessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final modeColor = _modeColor(session.controlMode);
    final distStr = _formatDistance(session.totalDistanceM);
    final durStr = _formatDuration(session.duration);

    return GestureDetector(
      onTap: () => _openDetail(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: session.completed ? AppColors.disabled : AppColors.warning,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ------ Cabecera — fecha + modo de control + SITL + estado -------
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Flight ${_formatDate(session.startTime)}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Chip modo de control
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: modeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: modeColor),
                    ),
                    child: Text(
                      session.controlMode.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  // Chip SITL
                  if (session.isSitl) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange),
                      ),
                      child: const Text(
                        'SITL',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              // Estado completado / interrumpido
              Row(
                children: [
                  Icon(
                    session.completed
                        ? Icons.check_circle
                        : Icons.warning_amber,
                    size: 12,
                    color: session.completed
                        ? AppColors.primary
                        : AppColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    session.completed ? 'Completed' : 'Interrupted',
                    style: TextStyle(
                      color: session.completed
                          ? AppColors.primary
                          : AppColors.warning,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ------ Métricas — duration + distancia + altitud ------ 
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricTile(Icons.timer_outlined, durStr, 'Duration'),
                  _MetricTile(Icons.straighten, distStr, 'Distance'),
                  _MetricTile(
                    Icons.height,
                    '${session.maxAlt.toStringAsFixed(1)} m',
                    'Max Alt',
                  ),
                  _MetricTile(
                    Icons.trending_up,
                    '${session.altGain.toStringAsFixed(1)} m',
                    'Desnivel',
                  ),
                  _MetricTile(
                    Icons.speed,
                    '${session.maxSpeed.toStringAsFixed(1)} m/s',
                    'Max Spd',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper para abrir el bottom sheet con el detalle completo del vuelo.
  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FlightDetailSheet(session: session),
    );
  }
}

// ------ TILE DE MÉTRICA --------------------------

// Icono + valor + etiqueta para mostrar una métrica concreta de la sesión. Se usa tanto en la tarjeta de resumen como en el detail sheet.
class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _MetricTile(this.icon, this.value, this.label);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.primary, size: 14),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 9),
        ),
      ],
    );
  }
}

// ----- DETAIL SHEET ---------------------------

// Bottom sheet que muestra el detalle completo de la sesión: mapa con la trayectoria, slider temporal para explorar el vuelo, 
//estadísticas detalladas y botón de descarga del CSV. Se abre al pulsar una tarjeta de sesión en la lista principal.
class _FlightDetailSheet extends StatefulWidget {
  final FlightSession session;
  const _FlightDetailSheet({required this.session});

  @override
  State<_FlightDetailSheet> createState() => _FlightDetailSheetState();
}

class _FlightDetailSheetState extends State<_FlightDetailSheet> {
  final MapController _mapController = MapController();
  int _playIndex = 0; // índice del punto visible actualmente en el slider

  @override
  void initState() {
    super.initState();
    // El slider arranca al final para mostrar el vuelo completo
    _playIndex = (widget.session.trail.length - 1).clamp(0, 999999);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitTrail());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // Encuadra la cámara del mapa para mostrar toda la trayectoria.
  void _fitTrail() {
    final trail = widget.session.trail;
    if (trail.isEmpty) return;
    if (trail.length == 1) {
      try {
        _mapController.move(trail.first, 17);
      } catch (_) {}
      return;
    }
    final lats = trail.map((p) => p.latitude);
    final lons = trail.map((p) => p.longitude);
    final sw = LatLng(lats.reduce(min), lons.reduce(min));
    final ne = LatLng(lats.reduce(max), lons.reduce(max));
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(sw, ne),
          padding: const EdgeInsets.all(48),
        ),
      );
    } catch (_) {}
  }

  // Texto de telemetría para el punto actual del slider.
  // Interpola el índice del trail al índice del log.
  String _snapshotInfo() {
    final log = widget.session.log;
    final trail = widget.session.trail;
    if (log.isEmpty || trail.isEmpty) return '';
    final ratio = _playIndex / (trail.length - 1).clamp(1, 999999);
    final logIdx = (ratio * (log.length - 1)).round().clamp(0, log.length - 1);
    final s = log[logIdx];
    return 'Alt ${s.alt.toStringAsFixed(1)} m  ·  '
        '${s.speed.toStringAsFixed(1)} m/s  ·  '
        'HDG ${s.heading.toStringAsFixed(0)}°  ·  '
        'BAT ${s.bat.toStringAsFixed(0)} %';
  }

  // Ángulo de orientación del dron en el punto actual del slider (radianes).
  double _droneHeading() {
    final trail = widget.session.trail;
    if (trail.length < 2 || _playIndex == 0) return 0;
    final from = trail[_playIndex - 1];
    final to = trail[_playIndex];
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final dLon = (to.longitude - from.longitude) * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return atan2(y, x);
  }

  // Construye el contenido del CSV.
  // Las columnas son idénticas a las que genera EZDrone al descargar un vuelo.
  String _buildCSV() {
    final sb = StringBuffer();
    sb.writeln('timestamp,lat,lon,alt_m,speed_ms,bat_pct,heading_deg');
    for (final s in widget.session.log) {
      sb.writeln(
        '${s.timestamp.toIso8601String()},'
        '${s.lat.toStringAsFixed(7)},'
        '${s.lon.toStringAsFixed(7)},'
        '${s.alt.toStringAsFixed(2)},'
        '${s.speed.toStringAsFixed(2)},'
        '${s.bat.toStringAsFixed(1)},'
        '${s.heading.toStringAsFixed(1)}',
      );
    }
    return sb.toString();
  }

  // Dispara la descarga del CSV en el navegador mediante un <a> temporal.
  // En EZDrone real este helper se llama downloadCSVEZ() y está en fullscreen.dart.
  void _downloadCSV() {
    if (!kIsWeb) return;
    final csv = _buildCSV();
    final dateStr = widget.session.startTime
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final encoded = Uri.encodeComponent(csv);
    final dataHref = 'data:text/csv;charset=utf-8,$encoded';
    // Inyección de <a> temporal — equivale a downloadCSVEZ() en EZDrone
    _triggerAnchorDownload(dataHref, 'flight_$dateStr.csv');
  }

  void _triggerAnchorDownload(String href, String filename) {
    // En EZDrone se usa dart:js_interop / web package. Aquí usamos eval mínimo.
    try {
      final _ = Uri.parse(href); // valida que el URI es correcto
      // La descarga real se delega al helper de EZDrone en producción.
      _showCSVDialog(_buildCSV());
    } catch (_) {}
  }

  // Fallback: muestra el CSV en un diálogo con texto seleccionable.
  // Útil cuando el entorno no permite disparar descargas programáticamente.
  void _showCSVDialog(String csv) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'CSV Preview',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            csv,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Close',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  Marker _buildMarker({
    required LatLng point,
    required IconData icon,
    required Color color,
  }) {
    return Marker(
      point: point,
      width: 26,
      height: 26,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(icon, color: Colors.white, size: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final trail = session.trail;
    final hasTrail = trail.length >= 2;
    final modeColor = _modeColor(session.controlMode);

    final visibleTrail = hasTrail
        ? trail.sublist(0, _playIndex + 1)
        : <LatLng>[];
    final currentPoint = hasTrail ? trail[_playIndex] : null;
    final LatLng center = hasTrail
        ? LatLng(
            trail.map((p) => p.latitude).reduce((a, b) => a + b) / trail.length,
            trail.map((p) => p.longitude).reduce((a, b) => a + b) /
                trail.length,
          )
        : const LatLng(41.2745, 1.9880);

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ----- Drag handle 
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.disabled,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ------ Cabecera — fecha + modo de control + SITL + estado 
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Flight ${_formatDate(session.startTime)}',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Icon(
                              session.completed
                                  ? Icons.check_circle
                                  : Icons.warning_amber,
                              size: 12,
                              color: session.completed
                                  ? AppColors.primary
                                  : AppColors.warning,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              session.completed ? 'Completed' : 'Interrupted',
                              style: TextStyle(
                                color: session.completed
                                    ? AppColors.primary
                                    : AppColors.warning,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: modeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: modeColor),
                    ),
                    child: Text(
                      session.controlMode.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (session.isSitl) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange),
                      ),
                      child: const Text(
                        'SITL',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -------- Mapa satelital con trayectoria del vuelo 
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 240,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: hasTrail
                      ? FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: center,
                            initialZoom: 17,
                          ),
                          children: [
                            // Tiles satélite ArcGIS — mismo proveedor que EZDrone
                            TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/'
                                  'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName: 'com.example.app',
                            ),
                            // Trail completo en gris de fondo
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: trail,
                                  color: Colors.white24,
                                  strokeWidth: 2.0,
                                ),
                              ],
                            ),
                            // Trail visible hasta _playIndex en violeta
                            if (visibleTrail.length >= 2)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: visibleTrail,
                                    color: const Color(0xFF7928CA),
                                    strokeWidth: 3.0,
                                  ),
                                ],
                              ),
                            // Marcadores takeoff / landing / posición actual
                            MarkerLayer(
                              markers: [
                                _buildMarker(
                                  point: trail.first,
                                  icon: Icons.flight_takeoff,
                                  color: AppColors.primary,
                                ),
                                _buildMarker(
                                  point: trail.last,
                                  icon: session.completed
                                      ? Icons.flight_land
                                      : Icons.warning_amber,
                                  color: session.completed
                                      ? AppColors.danger
                                      : AppColors.warning,
                                ),
                                if (currentPoint != null)
                                  Marker(
                                    point: currentPoint,
                                    width: 28,
                                    height: 28,
                                    child: Transform.rotate(
                                      angle: _droneHeading(),
                                      child: const Icon(
                                        Icons.navigation,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        )
                      : Container(
                          color: AppColors.background,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.gps_off,
                                  color: AppColors.textSecondary,
                                  size: 36,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'No GPS data available',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),

            // ------- Slider temporal 
            if (hasTrail) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        _snapshotInfo(),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: AppColors.primary,
                        inactiveTrackColor: AppColors.disabled,
                        thumbColor: AppColors.primary,
                        overlayColor: AppColors.primary,
                      ),
                      child: Slider(
                        value: _playIndex.toDouble(),
                        min: 0,
                        max: (trail.length - 1).toDouble(),
                        onChanged: (v) =>
                            setState(() => _playIndex = v.round()),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDate(session.startTime),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9,
                            ),
                          ),
                          Text(
                            _formatDate(
                              session.startTime.add(session.duration),
                            ),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),

            // ------- Estadísticas
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _StatCard(
                        Icons.timer_outlined,
                        'Duration',
                        _formatDuration(session.duration),
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.straighten,
                        'Distance',
                        _formatDistance(session.totalDistanceM),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.height,
                        'Max Alt',
                        '${session.maxAlt.toStringAsFixed(1)} m',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.trending_up,
                        'Desnivel',
                        '${session.altGain.toStringAsFixed(1)} m',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.speed,
                        'Max Speed',
                        '${session.maxSpeed.toStringAsFixed(1)} m/s',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.battery_full,
                        'Min Battery',
                        '${session.minBat.toStringAsFixed(0)} %',
                        valueColor: session.minBat < 20
                            ? AppColors.danger
                            : session.minBat < 50
                            ? AppColors.warning
                            : AppColors.primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.format_list_numbered,
                        'Snapshots',
                        '${session.log.length}',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.check_circle_outline,
                        'Status',
                        session.completed ? 'Completed' : 'Interrupted',
                        valueColor: session.completed
                            ? AppColors.primary
                            : AppColors.warning,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // -------- Botón DOWNLOAD CSV 
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text(
                    'DOWNLOAD CSV',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textPrimary,
                    disabledBackgroundColor: AppColors.disabled,
                    disabledForegroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: session.log.isEmpty ? null : _downloadCSV,
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// -------- TARJETA DE ESTADÍSTICA --------------------------

// Tarjeta rectangular con icono + etiqueta + valor para mostrar una estadística concreta de la sesión en el detail sheet.
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCard(this.icon, this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: 20),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -------- HELPERS ----------------------------

/// Color del chip según el modo de control.
Color _modeColor(String mode) {
  switch (mode.toLowerCase()) {
    case 'classic':
      return AppColors.primary;
    case 'voice':
      return Colors.teal;
    case 'imu':
      return Colors.deepPurple;
    default:
      return AppColors.textSecondary;
  }
}

// Formatea una duración como H:MM:SS o MM:SS.
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// Formatea una distancia en metros o kilómetros con unidades.
String _formatDistance(double meters) {
  if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

// Formatea una fecha como DD MMM YYYY  HH:MM.
String _formatDate(DateTime dt) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $h:$m';
}
