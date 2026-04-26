import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/fullscreen.dart';

// Pantalla de historial de vuelos.
// Muestra las sesiones grabadas con mapa, estadísticas y opción de descarga CSV.
class FlightLogScreen extends StatelessWidget {
  const FlightLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final sessions = provider.flightHistory;
    final screenH = MediaQuery.of(context).size.height;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('FLIGHT LOG', style: TextStyles.title),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
        actions: [
          // Badge con el número de sesiones guardadas
          if (sessions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary),
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
          // Botón borrar todo — solo visible si hay sesiones
          if (sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: AppColors.danger),
              tooltip: 'Clear all flights',
              onPressed: () => _confirmClearAll(context),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: sessions.isEmpty
          ? _buildEmpty()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: sessions.length,
              itemBuilder: (ctx, i) => _SessionCard(
                session: sessions[i],
                realIndex: i, // índice real en la lista para borrar
              ),
            ),
    );
  }

  // Diálogo de confirmación para borrar todo el historial
  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear all flights?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will permanently delete all flight records.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().clearAllSessions();
              Navigator.pop(context);
            },
            child: const Text(
              'Delete all',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  // Estado vacío — todavía no hay vuelos grabados en esta sesión
  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flight_land, size: 64, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text(
            'No flights yet',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Complete a flight to see it here',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

//-------- LISTA DE SESIONES ------------------

// Tarjeta de resumen de una sesión.
// Muestra los datos más relevantes y abre el detail sheet al pulsar.
class _SessionCard extends StatelessWidget {
  final FlightSession session;
  final int realIndex; // índice real en flightHistory para poder borrarlo

  const _SessionCard({required this.session, required this.realIndex});

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
              // Cabecera: nombre del vuelo, modo, estado y borrar
              Row(
                children: [
                  // Nombre: Flight + fecha y hora de inicio
                  Expanded(
                    child: Text(
                      'Flight  ${_formatDate(session.startTime)}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Chip del modo de control con su color propio
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
                  const SizedBox(width: 4),
                  // Chip SITL — solo si fue simulación
                  if (session.isSitl)
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
                  if (session.isSitl) const SizedBox(width: 4),
                  // Botón borrar esta sesión
                  GestureDetector(
                    onTap: () => _confirmDelete(context),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Indicador completado / interrumpido
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

              // ----- DATOS PRINCIPALES: duración, distancia, altitud máxima, desnivel y velocidad máxima -------------
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

  // Diálogo de confirmación para borrar esta sesión concreta
  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Delete this flight?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Flight ${_formatDate(session.startTime)} will be permanently deleted.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().deleteFlightSession(realIndex);
              Navigator.pop(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  // Abre el bottom sheet de detalle con mapa y estadísticas completas
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

// Tile de métrica reutilizable dentro de la card
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

// --------- DETAIL SHEET DE LA SESIÓN ----------------

class _FlightDetailSheet extends StatefulWidget {
  final FlightSession session;

  const _FlightDetailSheet({required this.session});

  @override
  State<_FlightDetailSheet> createState() => _FlightDetailSheetState();
}

// Bottom sheet de detalle — mapa interactivo del trail + grid de estadísticas + botón de descarga CSV.
class _FlightDetailSheetState extends State<_FlightDetailSheet> {
  final MapController _mapController = MapController();
  int _playIndex = 0; // índice hasta donde se muestra el trail

  @override
  void initState() {
    super.initState();
    _playIndex = (widget.session.trail.length - 1).clamp(
      0,
      double.maxFinite.toInt(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitTrail());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

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

  void _downloadCSV() {
    final csv = _buildCSV();
    final dateStr = widget.session.startTime
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    downloadCSVEZ('flight_$dateStr.csv', csv);
  }

  // Devuelve el snapshot del log correspondiente al punto actual del slider
  // (interpola el índice del trail al índice del log)
  String _snapshotInfo() {
    final log = widget.session.log;
    if (log.isEmpty || widget.session.trail.isEmpty) return '';
    final ratio =
        _playIndex / (widget.session.trail.length - 1).clamp(1, 999999);
    final logIdx = (ratio * (log.length - 1)).round().clamp(0, log.length - 1);
    final s = log[logIdx];
    final h = s.heading.toStringAsFixed(0);
    final alt = s.alt.toStringAsFixed(1);
    final spd = s.speed.toStringAsFixed(1);
    final bat = s.bat.toStringAsFixed(0);
    return 'Alt ${alt}m  ·  ${spd}m/s  ·  HDG ${h}°  ·  BAT ${bat}%';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final trail = session.trail;
    final hasTrail = trail.length >= 2;
    final modeColor = _modeColor(session.controlMode);

    // Trail visible: solo hasta _playIndex
    final visibleTrail = hasTrail
        ? trail.sublist(0, _playIndex + 1)
        : <LatLng>[];
    final currentPoint = hasTrail ? trail[_playIndex] : null;

    final LatLng mapCenter = hasTrail
        ? LatLng(
            trail.map((p) => p.latitude).reduce((a, b) => a + b) / trail.length,
            trail.map((p) => p.longitude).reduce((a, b) => a + b) /
                trail.length,
          )
        : const LatLng(41.2765, 1.9888);

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

            // ── Cabecera ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Flight  ${_formatDate(session.startTime)}',
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
                  // Chip del modo
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
                  // Chip SITL
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

            // ── Mapa ──────────────────────────────────────────────
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
                            initialCenter: mapCenter,
                            initialZoom: 17,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/'
                                  'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName: 'com.example.app',
                            ),
                            // Trail completo en gris tenue de fondo
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: trail,
                                  color: Colors.white24,
                                  strokeWidth: 2.0,
                                ),
                              ],
                            ),
                            // Trail visible hasta _playIndex en color primario
                            if (visibleTrail.length >= 2)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: visibleTrail,
                                    color: AppColors.primary,
                                    strokeWidth: 3.0,
                                  ),
                                ],
                              ),

                            // Marcadores despegue / aterrizaje
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
                                // Marcador dron en posición actual del slider
                                if (currentPoint != null)
                                  Marker(
                                    point: currentPoint,
                                    width: 34,
                                    height: 34,
                                    child: Transform.rotate(
                                      angle: _droneHeading(),
                                      child: Image.asset(
                                        'assets/images/drone_icon.png',
                                        width: 30,
                                        height: 30,
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

            // ── Slider de tiempo ─────────────────────────────────
            if (hasTrail) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    // Info del snapshot actual
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
                        // Sin divisions para movimiento suave
                        onChanged: (v) =>
                            setState(() => _playIndex = v.round()),
                      ),
                    ),
                    // Etiquetas inicio / fin
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

            // ── Estadísticas ──────────────────────────────────────
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

            // ── Botón CSV ─────────────────────────────────────────
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

  // Calcula el ángulo de orientación del dron en el punto actual del slider
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
}

// Tarjeta de estadística individual — icono + etiqueta + valor
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

// --------- FUNCIONES AUXILIARES ----------------

// Color del chip según el modo de control
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

// Formatea una duración como MM:SS o H:MM:SS
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// Formatea metros como "XXX m" o "X.XX km"
String _formatDistance(double meters) {
  if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

// Formatea una fecha como "15 Apr 2026 · 12:30"
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
