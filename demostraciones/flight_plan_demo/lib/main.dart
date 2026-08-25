import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web/web.dart' as web;

// ============================================================
// DEMO: FLIGHT PLAN — PLANIFICAR MISIONES CON WAYPOINTS
// ============================================================
//
// Esta app enseña a montar un plan de vuelo a base de waypoints para
// un dron ArduPilot y a exportarlo como JSON, ya listo para mandárselo
// a la estación de tierra.
//
// LIBRERÍAS:
//   flutter_map: ^7.0.2  - Mapa satelital interactivo (tiles de ArcGIS)
//   latlong2: ^0.9.1     - Tipo LatLng para las coordenadas
//
// FUNCIONAMIENTO:
//   1. Se toca el mapa y va apareciendo un waypoint numerado por cada toque.
//   2. Al tocar un marcador se abre un diálogo para editarlo:
//        - Altitud (entre 2 y 120 m)
//        - Acción al llegar: none / hover / photo / record / RTL / land
//        - Duración (solo para hover y record)
//   3. Los waypoints se pueden reordenar arrastrándolos en la lista.
//   4. El botón DOWNLOAD baja el plan entero como fichero JSON.
//
// FORMATO DEL JSON EXPORTADO:
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
// ACCIONES DISPONIBLES POR WAYPOINT:
//   none        - sigue al siguiente sin pararse
//   hover       - se queda quieto N segundos
//   takePhoto   - dispara la cámara
//   recordVideo - graba vídeo durante N segundos
//   rtl         - Return to Launch (da la misión por terminada)
//   land        - aterriza en ese punto
//
// CÓMO ENCAJA EN EZDRONE:
//   El JSON que sale de aquí es exactamente el formato que EZDrone
//   publica por MQTT en el topic:
//     mobileFlutter/groundStation/mission
//   La estación de tierra lo recibe, lo carga en
//   ArduPilot y va ejecutando los waypoints en orden.
// ============================================================

// -------- MODELOS -----------------------------------------------------------------

// Tipos de acción que puede tener un waypoint
enum WaypointActionType { none, hover, takePhoto, recordVideo, rtl, land }

// Acción que ejecuta el dron al llegar a un waypoint: el tipo + su duración
class WaypointAction {
  final WaypointActionType type;
  final double seconds;
  const WaypointAction({
    this.type = WaypointActionType.none,
    this.seconds = 5.0,
  });

  // Crea una copia de la acción cambiando solo los campos que se pasen
  WaypointAction copyWith({WaypointActionType? type, double? seconds}) =>
      WaypointAction(type: type ?? this.type, seconds: seconds ?? this.seconds);

  // Texto corto para mostrar la acción en la interfaz
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
  // Vuelca la acción a JSON (el tipo como texto + los segundos)
  Map<String, dynamic> toJson() => {'type': type.name, 'seconds': seconds};
}

// Un waypoint del plan: dónde (lat, lon), a qué altura y qué hacer al llegar
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

  // Vuelca el waypoint a JSON: lat, lon, altitud y la acción
  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'altM': altM,
    'action': action.toJson(),
  };
}

// -------- COLORES -----------------------------------------------------------------

// Paleta de colores de la app (mismos tonos oscuros que EZDrone)
class C {
  static const background = Color(0xFF1E1E2E);
  static const surface = Color(0xFF2A2A3E);
  static const primary = Color(0xFF4F98A3);
  static const danger = Color(0xFFE05C5C);
  static const warning = Color(0xFFE8A835);
  static const disabled = Color(0xFF555568);
  static const text = Color(0xFFCDCCCA);
  static const textMuted = Color(0xFF797876);
}

  // ----------  MAIN  -------------------------------------------------------

// Punto de entrada
void main() {
  runApp(
    const MaterialApp(
      home: FlightPlanDemo(),
    ),
  );
}

// ---------- WIDGET PRINCIPAL ---------------------------------------------------

// Pantalla de la demo: junta el mapa, la lista de waypoints y el botón de descarga
class FlightPlanDemo extends StatefulWidget {
  const FlightPlanDemo({super.key});
  @override
  State<FlightPlanDemo> createState() => _FlightPlanDemoState();
}

class _FlightPlanDemoState extends State<FlightPlanDemo> {
  final MapController _mapController = MapController(); // controla el mapa (mover/zoom)
  List<FlightWaypoint> _waypoints = [];                 // waypoints del plan, en orden

  // si no hay ningun waypoint, el mapa se centra en la EETAC 
  static const LatLng _defaultCenter = LatLng(41.2765, 1.9888);

  // Al cerrar la pantalla se libera el controlador del mapa
  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // ------ ACCIONES SOBRE WAYPOINTS -----------------------------------------------

  // Cada toque en el mapa añade un waypoint nuevo al final de la lista
  void _onMapTap(TapPosition _, LatLng point) {
    setState(() {
      _waypoints = [
        ..._waypoints,
        FlightWaypoint(lat: point.latitude, lon: point.longitude),  // lat y lon del toque, altitud por defecto 10 m y acción por defecto none
      ];
    });
  }

  // Borra el waypoint que está en esa posición de la lista
  void _removeWaypoint(int index) {
    setState(() => _waypoints = List.from(_waypoints)..removeAt(index));
  }

  // Recoloca un waypoint después de arrastrarlo a otra posición
  void _reorderWaypoints(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {                                                 // setState para que se repinte la lista de waypoints
      final list = List<FlightWaypoint>.from(_waypoints);
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      _waypoints = list;
    });
  }

  // ------ DESCARGA DEL JSON ----------------------------------------------
  //
  // En Flutter Web bajar un fichero se hace a mano: se crea un Blob, se le
  // saca una URL temporal y se simula un click sobre un <a download>. Fuera
  // de Web (móvil/escritorio) eso no vale, así que en su lugar se enseña el
  // JSON en un diálogo para poder copiarlo.
  void _downloadJson() {
    if (_waypoints.isEmpty) return;
    final plan = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': _planName,
      'waypoints': _waypoints.map((w) => w.toJson()).toList(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(plan);
    final filename = '${_planName.replaceAll(' ', '_')}.json';

    if (kIsWeb) {
      _descargarWeb(jsonStr, 'application/json', filename);
    } else {
      // Fuera de Web no hay descarga nativa en esta demo: se muestra el JSON
      _showJsonPreview(jsonStr);
    }
  }

  // Descarga de verdad en el navegador: Blob -> objectURL -> click en <a download>
  void _descargarWeb(String contenido, String mime, String filename) {
    final blob = web.Blob(
      [contenido.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }

  // Enseña el JSON en un diálogo con el texto seleccionable (para copiarlo)
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

  // ------ HELPERS ------------------------------------------------

  // Nombre automático del plan a partir de la fecha de hoy
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

  // Longitud total de la ruta: suma de las distancias entre waypoints seguidos
  double get _totalDistM {
    if (_waypoints.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < _waypoints.length; i++) {
      const R = 6371000.0; // radio de la Tierra en metros (para Haversine)
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

  // Formatea una distancia: metros por debajo de 1 km, si no en kilómetros
  String _fmtDist(double m) => m < 1000
      ? '${m.toStringAsFixed(0)} m'
      : '${(m / 1000).toStringAsFixed(2)} km';

  // Centra el mapa en la media de todos los waypoints (o en la EETAC si no hay)
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

  // Color con el que se pinta cada tipo de acción (en marcador y en la lista)
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

  // ------ DIÁLOGO DE EDICIÓN DE WAYPOINT -----------------------------------------------

  // Abre el diálogo para cambiar la altitud y la acción de un waypoint
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

    // StatefulBuilder deja repintar solo el diálogo al cambiar la acción elegida,
    // sin tener que reconstruir toda la pantalla
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
                  decoration: _inputDec(suffix: 'm'),       // decoración común de los TextField 
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
                      onTap: () => setDS(                             // onTap: () => setDS( para repintar solo el diálogo, no toda la pantalla
                        () =>
                            currentAction = currentAction.copyWith(type: type), // cambia la acción elegida, manteniendo los segundos
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: sel ? C.primary.withValues(alpha: 0.2) : C.background,
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
              onPressed: () => Navigator.pop(ctx),                                        // cierra el diálogo sin guardar cambios
              child: const Text('Cancel', style: TextStyle(color: C.textMuted)),
            ),
            TextButton(
              onPressed: () {                                                                       // guarda los cambios: altitud y acción (con segundos si aplica)
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
                Navigator.pop(ctx);     // cierra el diálogo tras guardar los cambios
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

  // Decoración común de los TextField del diálogo (altitud y duración)
  InputDecoration _inputDec({String? suffix}) => InputDecoration(
    filled: true,
    fillColor: C.background,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.background,
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

        // Botón de borrar todos los waypoints (solo aparece si hay alguno)
        actions: [
          if (_waypoints.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: C.danger),
              tooltip: 'Clear all',
              onPressed: () => showDialog(  //abre un diálogo de confirmación antes de borrar todos los waypoints
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: C.surface,
                  title: const Text(
                    'Clear all waypoints?',
                    style: TextStyle(color: C.text),
                  ),
                  actions: [
                    // Dos botones: Cancelar y Borrar
                    TextButton(
                      onPressed: () => Navigator.pop(context),    // cierra el diálogo sin borrar nada
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: C.textMuted),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => _waypoints = []);    // vacía la lista de waypoints
                        Navigator.pop(context);           // cierra el diálogo
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
                    onTap: _onMapTap,   // llama al método que añade un waypoint al tocar el mapa
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.example.flight_plan_demo',
                    ),

                    // Línea que une los waypoints en orden (la ruta)
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

                    // Marcadores numerados (verde el primero, rojo el último)
                    MarkerLayer(
                      markers: [
                        for (int i = 0; i < _waypoints.length; i++)
                          Marker(
                            point: LatLng(_waypoints[i].lat, _waypoints[i].lon),
                            width: 32,
                            height: 32,
                            child: GestureDetector(
                              onTap: () => _editWaypoint(i),  // al tocar un marcador se abre el diálogo de edición del waypoint
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
                                    '${i + 1}',   // número del waypoint
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


                // Pista flotante mientras el plan está vacío
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


                // Recuadro con el resumen (nº de waypoints + distancia total)
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


          // Lista de waypoints, reordenable arrastrando 
          Expanded(
            flex: 4,
            child: _waypoints.isEmpty
                ? const Center(
                    child: Text(
                      'No waypoints yet',   // mensaje cuando no hay waypoints
                      style: TextStyle(color: C.textMuted, fontSize: 13),
                    ),
                  )
                : ReorderableListView.builder(  
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    itemCount: _waypoints.length,
                    onReorder: _reorderWaypoints,   // llama al método que reordena los waypoints en la lista 
                    buildDefaultDragHandles: false,
                    itemBuilder: (ctx, i) {
                      final wp = _waypoints[i];
                      return _WaypointRow(
                        key: ValueKey('${wp.lat}${wp.lon}$i'),  // clave única para cada fila de la lista
                        index: i,
                        waypoint: wp,
                        actionColor: _actionColor(wp.action.type),
                        onTap: () {
                          _editWaypoint(i);
                          try {
                            _mapController.move(LatLng(wp.lat, wp.lon), 17);  // centra el mapa en el waypoint al abrir el diálogo de edición
                          } catch (_) {}
                        },
                        onDelete: () => _removeWaypoint(i), // llama al método que borra el waypoint de la lista
                      );
                    },
                  ),
          ),

          // Botón DOWNLOAD JSON (desactivado si no hay waypoints)
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
                onPressed: _waypoints.isNotEmpty ? _downloadJson : null,  // llama al método que descarga el JSON del plan de vuelo
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------ FILA DE WAYPOINT EN LA LISTA -------------------------------

// Cada fila de la lista: número, coordenadas, altitud, la etiqueta de acción
// y el botón de borrar. Lleva un asa para arrastrarla y reordenar el plan.
class _WaypointRow extends StatelessWidget {
  final int index;
  final FlightWaypoint waypoint;
  final Color actionColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _WaypointRow({
    super.key,              //key se usa para identificar de manera única cada fila en la lista reordenable
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
                  '${index + 1}',               // número del waypoint 
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
                    '${waypoint.lat.toStringAsFixed(5)}, ${waypoint.lon.toStringAsFixed(5)}',     // coordenadas del waypoint
                    style: const TextStyle(
                      color: C.text,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${waypoint.altM.toStringAsFixed(1)} m alt',                              // altitud del waypoint
                    style: const TextStyle(color: C.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (waypoint.action.type != WaypointActionType.none)  // si la acción no es "none", se muestra la etiqueta de acción
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: actionColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: actionColor),
                ),
                child: Text(
                  waypoint.action.label,  // etiqueta de acción del waypoint
                  style: TextStyle(
                    color: actionColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            GestureDetector(
              onTap: onDelete,    // llama al método que borra el waypoint de la lista
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
