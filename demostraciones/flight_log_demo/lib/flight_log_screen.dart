// ===========================================================================
// FLIGHT LOG SCREEN
// ===========================================================================
// Pantalla del historial de vuelos. Enseña la lista de sesiones grabadas y
// deja entrar al detalle de cada una: mapa con la trayectoria, un slider para
// recorrer el vuelo y la descarga del log en CSV.
//
// Aquí solo vive la parte visual (UI). Los datos salen de
// sample_flight_data.dart, que expone la lista sampleSessions. 
//
// QUÉ HAY EN ESTE FICHERO:
//   AppColors           - paleta de colores
//   FlightLogScreen     - la lista principal de sesiones
//   _SessionCard        - la tarjeta resumen de una sesión
//   _MetricTile         - una métrica suelta (icono + valor + etiqueta)
//   _FlightDetailSheet  - el panel de detalle (mapa, slider y estadísticas)
//   _StatCard           - una tarjeta de estadística dentro del detalle
//   Helpers             - _modeColor, _formatDuration, _formatDistance,
//                         _formatDate
// ===========================================================================

import 'dart:js_interop';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;  
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web/web.dart' as web;
import 'sample_flight_data.dart';

// -------- COLORES ------------------------------

// Paleta de la app 
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

// Lista las sesiones de vuelo. Cada una aparece en una tarjeta con sus métricas
// principales; al tocarla se abre el panel con el detalle completo del vuelo.
class FlightLogScreen extends StatelessWidget {
  const FlightLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sessions = sampleSessions;  // lista de vuelos de ejemplo, importada de sample_flight_data.dart
    final screenH = MediaQuery.of(context).size.height;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;  // true si la pantalla está en horizontal 

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
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06, // altura de la barra superior según orientación
        actions: [

          // Contador con el número de vuelos guardados
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
                  '${sessions.length}', // número de vuelos guardados
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

      // Lista scrollable, una tarjeta por sesión
      body: ListView.builder(                       // lista de vuelos
        padding: const EdgeInsets.all(12),
        itemCount: sessions.length,     // número de vuelos en la lista
        itemBuilder: (ctx, i) => _SessionCard(session: sessions[i]),      // cada tarjeta de vuelo se construye con _SessionCard, pasando la sesión correspondiente
      ),
    );
  }
}

// ------ TARJETA DE SESIÓN --------------------------

// Resumen de un vuelo con sus métricas principales. Al tocarla abre el panel
// de detalle con todo el vuelo.
class _SessionCard extends StatelessWidget {
  final FlightSession session;
  const _SessionCard({required this.session});

  @override 
  Widget build(BuildContext context) {  // Construye la tarjeta de vuelo con la información de la sesión
    final modeColor = _modeColor(session.controlMode);
    final distStr = _formatDistance(session.totalDistanceM);
    final durStr = _formatDuration(session.duration);

    return GestureDetector(   // Detecta el toque en la tarjeta para abrir el detalle del vuelo
      onTap: () => _openDetail(context),  // abre el panel inferior con el detalle del vuelo
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
              // ------ Cabecera: fecha + chip de modo + chip SITL -------
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Flight ${_formatDate(session.startTime)}', // fecha del vuelo
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Chip con el modo de control (CLASSIC / VOICE / IMU)
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
                  // Chip SITL, solo si el vuelo fue en el simulador
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

              // Línea de estado: completado (verde) o interrumpido (ámbar)
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

              // ------ Fila de métricas: duración, distancia, alturas y velocidad ------
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricTile(Icons.timer_outlined, durStr, 'Duration'),  // _metricTile es un widget que muestra un icono, un valor y una etiqueta
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

  // Abre el panel inferior (bottom sheet) con el detalle completo del vuelo
  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FlightDetailSheet(session: session), //builder devuelve el widget _FlightDetailSheet
    );
  }
}

// ------ TILE DE MÉTRICA --------------------------
// Bloque pequeño (icono + valor + etiqueta) para una métrica suelta. 
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

// ----- PANEL DE DETALLE ---------------------------

// Panel inferior con todo el detalle del vuelo: mapa con la trayectoria, slider
// para recorrer el vuelo punto a punto, tarjetas de estadísticas y el botón de
// descarga del CSV. Se abre al tocar una tarjeta de la lista principal.
class _FlightDetailSheet extends StatefulWidget {
  final FlightSession session;
  const _FlightDetailSheet({required this.session});

  @override
  State<_FlightDetailSheet> createState() => _FlightDetailSheetState(); // crea el estado del panel de detalle
}

class _FlightDetailSheetState extends State<_FlightDetailSheet> {
  final MapController _mapController = MapController();
  int _playIndex = 0; // hasta qué punto de la trayectoria llega el slider

  // Al abrir el panel: pone el slider al final (vuelo entero) y encuadra el mapa
  @override
  void initState() {
    super.initState();
    _playIndex = (widget.session.trail.length - 1).clamp(0, 999999);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitTrail());
  }

  // Libera el controlador del mapa al cerrar el panel
  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // Mueve y hace zoom en el mapa para que quepa toda la trayectoria
  void _fitTrail() {
    final trail = widget.session.trail;
    if (trail.isEmpty) return;
    if (trail.length == 1) {
      try {
        _mapController.move(trail.first, 17); // si solo hay un punto, centra el mapa ahí con zoom 17
      } catch (_) {}
      return;
    }
    // coordenadas SW y NE del rectángulo que encierra toda la trayectoria
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

  // Línea de telemetría del punto donde está el slider.
  // El trail y el log tienen tamaños distintos, así que se pasa el índice de
  // uno al otro por regla de tres.
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

  // Hacia dónde apunta el dron en el punto del slider (rumbo, en radianes).
  // Se calcula con el bearing entre el punto anterior y el actual.
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

  // Arma el texto del CSV, una fila por snapshot.
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

  // Lanza la descarga del CSV en el navegador con un <a> temporal.
  void _downloadCSV() {
    final csv = _buildCSV();    // se construye el csv
    final dateStr = widget.session.startTime  // fecha del vuelo en formato YYYY-MM-DDTHH-MM-SS
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final filename = 'flight_$dateStr.csv'; // nombre del archivo con la fecha del vuelo

    if (kIsWeb) { // si estamos en un navegador web, se lanza la descarga del CSV
      _descargarWeb(csv, 'text/csv;charset=utf-8', filename);
    } else {
      // Fuera de Web no hay descarga nativa aquí: se enseña el CSV para copiarlo
      _showCSVDialog(csv);
    }
  }

  // Descarga de verdad en el navegador: Blob -> objectURL -> click en <a download>
  void _descargarWeb(String contenido, String mime, String filename) {
    final blob = web.Blob(  // se crea un blob con el contenido del CSV
      [contenido.toJS].toJS,  // se convierte el contenido a JS
      web.BlobPropertyBag(type: mime),  // se indica el tipo MIME del blob
    );
    final url = web.URL.createObjectURL(blob);  // se crea un objectURL para el blob
    web.HTMLAnchorElement() // se crea un <a> temporal
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url); // se revoca el objectURL para liberar memoria
  }

  // Plan B: enseña el CSV en un diálogo con el texto seleccionable.
  // Sirve cuando el entorno no deja lanzar descargas por código.
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

  // Crea un marcador circular de color con un icono dentro (despegue/aterrizaje)
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
  Widget build(BuildContext context) {    // Construye el panel de detalle del vuelo, con mapa, slider y estadísticas
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

    return DraggableScrollableSheet(  //DraggableScrollableSheet con info del vuelo
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ----- Asa para arrastrar el panel arriba/abajo
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

            // ------ Cabecera del detalle: fecha, estado y chips (modo + SITL)
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

            // -------- Mapa satelital con la trayectoria del vuelo
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
                            // Capa de tiles satélite de ArcGIS 
                            TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/'
                                  'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName: 'com.example.app',
                            ),

                            // Trayectoria completa, en gris de fondo
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: trail,
                                  color: Colors.white24,
                                  strokeWidth: 2.0,
                                ),
                              ],
                            ),

                            // Tramo ya recorrido (hasta el slider), en violeta
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

                            // Marcadores: despegue, aterrizaje y flecha de posición actual
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
                      : Container(      // si no hay trayectoria, enseña un mensaje de error
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

            // ------- Slider temporal: arrastra para recorrer el vuelo
            if (hasTrail) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        _snapshotInfo(),    // enseña la telemetría del punto actual del slider
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    SliderTheme(                                      // personaliza el aspecto del slider
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
                      child: Slider(  // slider con rango de 0 a trail.length - 1, que controla _playIndex
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
                          Text( // texto con la fecha y hora de inicio del vuelo
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

            // ------- Rejilla de estadísticas (dos tarjetas por fila)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _StatCard(  //duración del vuelo
                        Icons.timer_outlined,
                        'Duration',
                        _formatDuration(session.duration),
                      ),

                      const SizedBox(width: 10),  

                      _StatCard(  //distancia total recorrida
                        Icons.straighten,
                        'Distance',
                        _formatDistance(session.totalDistanceM),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(  //altura máxima alcanzada
                        Icons.height,
                        'Max Alt',
                        '${session.maxAlt.toStringAsFixed(1)} m',
                      ),

                      const SizedBox(width: 10),

                      _StatCard(  //desnivel alcanzado
                        Icons.trending_up,
                        'Desnivel',
                        '${session.altGain.toStringAsFixed(1)} m',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(  //velocidad máxima alcanzada
                        Icons.speed,
                        'Max Speed',
                        '${session.maxSpeed.toStringAsFixed(1)} m/s',
                      ),

                      const SizedBox(width: 10),

                      _StatCard(  //batería mínima alcanzada
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
                      _StatCard(  //número de snapshots guardados en el log
                        Icons.format_list_numbered,
                        'Snapshots',
                        '${session.log.length}',
                      ),

                      const SizedBox(width: 10),

                      _StatCard(  //estado final del vuelo: completado o interrumpido
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

            // -------- Botón DOWNLOAD CSV (desactivado si no hay log)
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
                  onPressed: session.log.isEmpty ? null : _downloadCSV, // al pulsar el botón, se descarga el CSV si hay log, si no está desactivado
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

// Tarjeta (icono + etiqueta + valor) para una estadística del panel de detalle.
// valueColor deja pintar el valor en rojo/ámbar según el caso (p. ej. batería baja).
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

// Color del chip según el modo de control (classic/voice/imu)
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

// Formatea una duración como H:MM:SS (o MM:SS si no llega a una hora)
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// Formatea una distancia: metros por debajo de 1 km, si no en kilómetros
String _formatDistance(double meters) {
  if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

// Formatea una fecha como "DD Mmm YYYY · HH:MM"
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
