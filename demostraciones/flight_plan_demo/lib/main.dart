import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// ============================================================
// DEMO: FLIGHT PLAN - CREACIÓN DE MISIONES CON WAYPOINTS
// ============================================================
//
// Esta app demuestra cómo crear un plan de vuelo con waypoints
// para un dron ArduPilot y exportarlo como JSON listo para
// ser enviado a la estación tierra.
//
// LIBRERÍAS:
//   flutter_map: ^7.0.2  - Mapa satelital interactivo (ArcGIS)
//   latlong2: ^0.9.1     - Coordenadas geográficas
//
// FUNCIONAMIENTO:
//   1. El usuario toca el mapa para colocar waypoints numerados.
//   2. Tapping un marcador abre un diálogo para editar:
//        - Altitud (2–120 m)
//        - Acción al llegar: none / hover / photo / record / RTL / land
//        - Duración (para hover y record)
//   3. Los waypoints son reordenables con drag & drop.
//   4. DOWNLOAD exporta el plan completo como JSON.
//
// FORMATO JSON EXPORTADO:
//   {
//     "id": "1715000000000",
//     "name": "Plan 01 May 2025",
//     "waypoints": [
//       {
//         "lat": 41.27650,
//         "lon": 1.98880,
//         "altM": 10.0,
//         "action": { "type": "hover", "seconds": 3.0 }
//       },
//       ...
//     ]
//   }
//
// ACCIONES POR WAYPOINT:
//   none        - Pasa al siguiente sin detenerse
//   hover       - Mantiene posición N segundos
//   takePhoto   - Dispara cámara
//   recordVideo - Graba N segundos
//   rtl         - Return to Launch (termina misión)
//   land        - Aterriza en ese punto
//
// INTEGRACIÓN EN EZDRONE:
//   El JSON generado aquí es exactamente el formato que
//   EZDrone envía vía MQTT al topic:
//     mobileFlutter/groundStation/mission
//   La estación tierra (estacion_tierra.py) lo recibe,
//   lo carga en ArduPilot vía DroneKit y ejecuta cada
//   waypoint secuencialmente.
// ============================================================

// -------- Modelos -----------------------------------------------------------------
enum WaypointActionType { none, hover, takePhoto, recordVideo, rtl, land }

// Acción asociada a un waypoint: tipo + duración (si aplica)
class WaypointAction {
  final WaypointActionType type;
  final double seconds;
  const WaypointAction({
    this.type = WaypointActionType.none,
    this.seconds = 3.0,
  });

  WaypointAction copyWith({WaypointActionType? type, double? seconds}) =>
      WaypointAction(type: type ?? this.type, seconds: seconds ?? this.seconds);

  // Etiqueta legible para el tipo de acción
  String get label {
    switch (type) {
      case WaypointActionType.none:
        return 'None';
      case WaypointActionType.hover:
        return 'Hover ${seconds.toStringAsFixed(0)}s';
      case WaypointActionType.takePhoto:
        return 'Photo';
      case WaypointActionType.recordVideo:
        return 'Rec ${seconds.toStringAsFixed(0)}s';
      case WaypointActionType.rtl:
        return 'RTL';
      case WaypointActionType.land:
        return 'Land';
    }
  }
  // Conversión a JSON (tipo como string + segundos)
  Map<String, dynamic> toJson() => {'type': type.name, 'seconds': seconds};
}

// Waypoint de vuelo: latitud, longitud, altitud y acción
class FlightWaypoint {
  final double lat;
  final double lon;
  final double altM;
  final WaypointAction action;

  const FlightWaypoint({
    required this.lat,
    required this.lon,
    this.altM = 10.0,
    this.action = const WaypointAction(),
  });

  FlightWaypoint copyWith({double? altM, WaypointAction? action}) =>
      FlightWaypoint(
        lat: lat,
        lon: lon,
        altM: altM ?? this.altM,
        action: action ?? this.action,
      );

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'altM': altM,
    'action': action.toJson(),
  };
}

// -------- Colores -----------------------------------------------------------------

// Paleta de colores personalizada para la app
class C {
  static const bg = Color(0xFF1E1E2E);
  static const surface = Color(0xFF2A2A3E);
  static const primary = Color(0xFF4F98A3);
  static const danger = Color(0xFFE05C5C);
  static const warning = Color(0xFFE8A835);
  static const disabled = Color(0xFF555568);
  static const text = Color(0xFFCDCCCA);
  static const textMuted = Color(0xFF797876);
}

  // ----------  MAIN  -------------------------------------------------------

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FlightPlanDemo(),
    ),
  );
}

// ---------- Widget principal ---------------------------------------------------

// Widget principal que contiene el mapa, la lista de waypoints y el botón de descarga
class FlightPlanDemo extends StatefulWidget {
  const FlightPlanDemo({super.key});
  @override
  State<FlightPlanDemo> createState() => _FlightPlanDemoState();
}

class _FlightPlanDemoState extends State<FlightPlanDemo> {
  final MapController _mapController = MapController();
  List<FlightWaypoint> _waypoints = [];

  // Centro por defecto: EETAC 
  static const LatLng _defaultCenter = LatLng(41.2765, 1.9888);

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // ------ Acciones sobre waypoints -----------------------------------------------

  // Al tocar el mapa, se añade un nuevo waypoint al final de la lista
  void _onMapTap(TapPosition _, LatLng point) {
    setState(() {
      _waypoints = [
        ..._waypoints,
        FlightWaypoint(lat: point.latitude, lon: point.longitude),
      ];
    });
  }

  // Elimina un waypoint por índice
  void _removeWaypoint(int index) {
    setState(() => _waypoints = List.from(_waypoints)..removeAt(index));
  }

  // Reordena los waypoints tras un drag & drop en la lista
  void _reorderWaypoints(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final list = List<FlightWaypoint>.from(_waypoints);
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      _waypoints = list;
    });
  }

  // ------ Descarga del JSON ----------------------------------------------
  //
  // En Flutter Web, la descarga se hace creando un elemento <a>
  // con un blob URL y disparando un click programático.

  // Aquí, para simplificar la demo, mostramos el JSON en un diálogo
  void _downloadJson() {
    if (_waypoints.isEmpty) return;
    final plan = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': _planName,
      'waypoints': _waypoints.map((w) => w.toJson()).toList(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(plan);

    // Flutter Web: inyecta un <a> con data URI y hace click
    Uri.encodeComponent(jsonStr);

    _showJsonPreview(jsonStr);
  }

  // Muestra el JSON generado en un diálogo con texto seleccionable
  void _showJsonPreview(String jsonStr) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.surface,
        title: Row(
          children: [
            const Icon(Icons.code, color: C.primary, size: 18),
            const SizedBox(width: 8),
            Text(
              _planName,
              style: const TextStyle(
                color: C.text,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              jsonStr,
              style: const TextStyle(
                color: C.text,
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: C.textMuted)),
          ),
        ],
      ),
    );
  }

  // ------ Helpers ------------------------------------------------

  // Genera un nombre de plan basado en la fecha actual
  String get _planName {
    final now = DateTime.now();
    const m = [
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
    return 'Plan ${now.day} ${m[now.month - 1]} ${now.year}';
  }

  // Calcula la distancia total de la ruta sumando las distancias entre waypoints
  double get _totalDistM {
    if (_waypoints.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < _waypoints.length; i++) {
      const R = 6371000.0;
      final a = _waypoints[i - 1];
      final b = _waypoints[i];
      final lat1 = a.lat * pi / 180;
      final lat2 = b.lat * pi / 180;
      final dLat = (b.lat - a.lat) * pi / 180;
      final dLon = (b.lon - a.lon) * pi / 180;
      final s =
          sin(dLat / 2) * sin(dLat / 2) +
          cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
      d += R * 2 * atan2(sqrt(s), sqrt(1 - s));
    }
    return d;
  }

  String _fmtDist(double m) => m < 1000
      ? '${m.toStringAsFixed(0)} m'
      : '${(m / 1000).toStringAsFixed(2)} km';

  LatLng get _mapCenter {
    if (_waypoints.isEmpty) return _defaultCenter;
    final lat =
        _waypoints.map((w) => w.lat).reduce((a, b) => a + b) /
        _waypoints.length;
    final lon =
        _waypoints.map((w) => w.lon).reduce((a, b) => a + b) /
        _waypoints.length;
    return LatLng(lat, lon);
  }

  Color _actionColor(WaypointActionType t) {
    switch (t) {
      case WaypointActionType.none:
        return C.disabled;
      case WaypointActionType.hover:
        return Colors.teal;
      case WaypointActionType.takePhoto:
        return Colors.amber;
      case WaypointActionType.recordVideo:
        return C.danger;
      case WaypointActionType.rtl:
        return C.warning;
      case WaypointActionType.land:
        return C.danger;
    }
  }

  // ------ Diálogo edición de waypoint -----------------------------------------------

  // Abre un diálogo para editar la altitud y acción de un waypoint
  void _editWaypoint(int index) {
    final wp = _waypoints[index];
    final altCtrl = TextEditingController(text: wp.altM.toStringAsFixed(1));
    final secsCtrl = TextEditingController(
      text: wp.action.seconds.toStringAsFixed(0),
    );
    WaypointAction currentAction = wp.action;

    String actionName(WaypointActionType t) {
      switch (t) {
        case WaypointActionType.none:
          return 'None';
        case WaypointActionType.hover:
          return 'Hover';
        case WaypointActionType.takePhoto:
          return 'Photo';
        case WaypointActionType.recordVideo:
          return 'Record';
        case WaypointActionType.rtl:
          return 'RTL';
        case WaypointActionType.land:
          return 'Land';
      }
    }

    // El diálogo se reconstruye con StatefulBuilder para actualizar la selección de acción
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDS) => AlertDialog(
          backgroundColor: C.surface,
          title: Text(
            'Waypoint ${index + 1}',
            style: const TextStyle(color: C.text, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${wp.lat.toStringAsFixed(6)}, ${wp.lon.toStringAsFixed(6)}',
                  style: const TextStyle(color: C.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Altitude (m)',
                  style: TextStyle(color: C.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: altCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: C.text),
                  decoration: _inputDec(suffix: 'm'),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Action',
                  style: TextStyle(color: C.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: WaypointActionType.values.map((type) {
                    final sel = currentAction.type == type;
                    return GestureDetector(
                      onTap: () => setDS(
                        () =>
                            currentAction = currentAction.copyWith(type: type),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: sel ? C.primary.withValues(alpha: 0.2) : C.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: sel ? C.primary : C.disabled,
                          ),
                        ),
                        child: Text(
                          actionName(type),
                          style: TextStyle(
                            color: sel ? C.primary : C.textMuted,
                            fontSize: 12,
                            fontWeight: sel
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (currentAction.type == WaypointActionType.hover ||
                    currentAction.type == WaypointActionType.recordVideo) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Duration (s)',
                    style: TextStyle(color: C.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: secsCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: C.text),
                    decoration: _inputDec(suffix: 's'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: C.textMuted)),
            ),
            TextButton(
              onPressed: () {
                final newAlt =
                    double.tryParse(altCtrl.text.replaceAll(',', '.')) ??
                    wp.altM;
                final newSecs =
                    double.tryParse(secsCtrl.text) ?? currentAction.seconds;
                setState(() {
                  final list = List<FlightWaypoint>.from(_waypoints);
                  list[index] = wp.copyWith(
                    altM: newAlt.clamp(2.0, 120.0),
                    action: currentAction.copyWith(seconds: newSecs),
                  );
                  _waypoints = list;
                });
                Navigator.pop(ctx);
              },
              child: const Text(
                'Save',
                style: TextStyle(color: C.primary, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Estilo de los TextField en el diálogo de edición de waypoint
  InputDecoration _inputDec({String? suffix}) => InputDecoration(
    filled: true,
    fillColor: C.bg,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: C.disabled),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: C.primary),
    ),
    suffixText: suffix,
    suffixStyle: const TextStyle(color: C.textMuted),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  // ------ BUILD -------------------------------------------

  // Construye la interfaz principal con el mapa, la lista de waypoints y el botón de descarga
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.surface,
        foregroundColor: C.text,
        elevation: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'FLIGHT PLAN DEMO',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            if (_waypoints.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: C.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_waypoints.length} WP',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_waypoints.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: C.danger),
              tooltip: 'Clear all',
              onPressed: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: C.surface,
                  title: const Text(
                    'Clear all waypoints?',
                    style: TextStyle(color: C.text),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: C.textMuted),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => _waypoints = []);
                        Navigator.pop(context);
                      },
                      child: const Text(
                        'Clear',
                        style: TextStyle(color: C.danger),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Mapa satelital
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _mapCenter,
                    initialZoom: 17,
                    onTap: _onMapTap,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.example.flight_plan_demo',
                    ),
                    // Línea de ruta
                    if (_waypoints.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _waypoints
                                .map((w) => LatLng(w.lat, w.lon))
                                .toList(),
                            color: const Color(0xFF7928C6),
                            strokeWidth: 2.5,
                          ),
                        ],
                      ),
                    // Marcadores numerados
                    MarkerLayer(
                      markers: [
                        for (int i = 0; i < _waypoints.length; i++)
                          Marker(
                            point: LatLng(_waypoints[i].lat, _waypoints[i].lon),
                            width: 32,
                            height: 32,
                            child: GestureDetector(
                              onTap: () => _editWaypoint(i),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i == 0
                                      ? C.primary
                                      : i == _waypoints.length - 1
                                      ? C.danger
                                      : C.surface,
                                  border: Border.all(
                                    color: C.primary,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color:
                                          (i == 0 || i == _waypoints.length - 1)
                                          ? Colors.white
                                          : C.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                // Hint sin waypoints
                if (_waypoints.isEmpty)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: C.surface.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Tap on the map to add waypoints',
                          style: TextStyle(color: C.textMuted, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                // Stats overlay (distancia total)
                if (_waypoints.length >= 2)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: C.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_waypoints.length} WP · ${_fmtDist(_totalDistM)}',
                        style: const TextStyle(
                          color: C.text,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Lista reordenable de waypoints
          Expanded(
            flex: 4,
            child: _waypoints.isEmpty
                ? const Center(
                    child: Text(
                      'No waypoints yet',
                      style: TextStyle(color: C.textMuted, fontSize: 13),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    itemCount: _waypoints.length,
                    onReorder: _reorderWaypoints,
                    buildDefaultDragHandles: false,
                    itemBuilder: (ctx, i) {
                      final wp = _waypoints[i];
                      return _WaypointRow(
                        key: ValueKey('${wp.lat}${wp.lon}$i'),
                        index: i,
                        waypoint: wp,
                        actionColor: _actionColor(wp.action.type),
                        onTap: () {
                          _editWaypoint(i);
                          try {
                            _mapController.move(LatLng(wp.lat, wp.lon), 17);
                          } catch (_) {}
                        },
                        onDelete: () => _removeWaypoint(i),
                      );
                    },
                  ),
          ),

          // Botón DOWNLOAD JSON
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            color: C.surface,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.download),
                label: const Text(
                  'DOWNLOAD JSON',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _waypoints.isNotEmpty
                      ? C.primary
                      : C.disabled,
                  foregroundColor: C.text,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _waypoints.isNotEmpty ? _downloadJson : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------ Row de waypoint en la lista -------------------------------

// Widget que representa cada waypoint en la lista, con su número, coordenadas, altitud, acción y botón de eliminación. Es reordenable con drag & drop.
class _WaypointRow extends StatelessWidget {
  final int index;
  final FlightWaypoint waypoint;
  final Color actionColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _WaypointRow({
    super.key,
    required this.index,
    required this.waypoint,
    required this.actionColor,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.disabled),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.drag_handle, size: 18, color: C.textMuted),
              ),
            ),
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: C.primary,
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${waypoint.lat.toStringAsFixed(5)}, ${waypoint.lon.toStringAsFixed(5)}',
                    style: const TextStyle(
                      color: C.text,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${waypoint.altM.toStringAsFixed(1)} m alt',
                    style: const TextStyle(color: C.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (waypoint.action.type != WaypointActionType.none)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: actionColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: actionColor),
                ),
                child: Text(
                  waypoint.action.label,
                  style: TextStyle(
                    color: actionColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            GestureDetector(
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.delete_outline, size: 16, color: C.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
