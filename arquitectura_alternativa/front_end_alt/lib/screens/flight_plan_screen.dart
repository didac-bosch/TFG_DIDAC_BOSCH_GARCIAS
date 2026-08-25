import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/drone_video_view.dart';

// ─── PANTALLA PRINCIPAL ───────────────────────────────────────────────────────
// Abre un mapa satélite interactivo para colocar waypoints y asignarles
// acciones. Permite guardar el plan localmente y subirlo al dron via MQTT.
//
// Tiene dos caras muy distintas y comparten pantalla:
//   - EDITOR: se toca el mapa para añadir waypoints, se reordenan arrastrando y
//     a cada uno se le puede dar una acción (hover, foto, vídeo, RTL, land).
//   - SEGUIMIENTO: una vez la misión está en marcha, la misma pantalla muestra
//     por qué waypoint va el dron, según los avisos que llegan de la estación.
//
// El plan se guarda en el navegador (localStorage vía el provider) y se sube al
// dron como un JSON por MQTT.

class FlightPlanScreen extends StatefulWidget {
  /// null = plan nuevo, non-null = editar plan existente
  final FlightPlan? existingPlan;

  const FlightPlanScreen({super.key, this.existingPlan});

  @override
  State<FlightPlanScreen> createState() => _FlightPlanScreenState();
}

class _FlightPlanScreenState extends State<FlightPlanScreen> {
  final MapController _mapController = MapController();
  late List<FlightWaypoint> _waypoints;
  late String _planId;
  late String _planName;
  bool _hasUnsavedChanges = false;

  // Centro por defecto — cerca de la EETAC
  static const LatLng _defaultCenter = LatLng(41.2765, 1.9888);

  @override
  void initState() {
    super.initState();
    // Si se abre para editar un plan existente se copia su contenido; si es un
    // plan nuevo, el id se genera con la hora actual en milisegundos (basta para
    // que sea único dentro de este navegador).
    // Ojo: se copia la lista, no se referencia. Así, si el usuario edita y no
    // guarda, el plan original no queda tocado.
    final plan = widget.existingPlan;
    _planId = plan?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    _waypoints = List<FlightWaypoint>.from(plan?.waypoints ?? []);
    _planName = plan?.name ?? _defaultPlanName();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _defaultPlanName() {
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

  // Distancia total del recorrido: suma de los tramos entre waypoints
  // consecutivos, usando la fórmula del haversine (distancia sobre la esfera
  // terrestre; con Pitágoras plano el error crecería con la distancia).
  double _calcTotalDist() {
    if (_waypoints.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < _waypoints.length; i++) {
      const R = 6371000.0; // radio medio de la Tierra, en metros
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

  String _fmtDist(double m) {
    if (m < 1000) return '${m.toStringAsFixed(0)} m';
    return '${(m / 1000).toStringAsFixed(2)} km';
  }

  // Centra el mapa en el punto medio de todos los waypoints, para que el plan
  // entero quede a la vista al abrirlo.
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
        return AppColors.disabled;
      case WaypointActionType.hover:
        return Colors.teal;
      case WaypointActionType.takePhoto:
        return Colors.amber;
      case WaypointActionType.recordVideo:
        return AppColors.danger;
      case WaypointActionType.rtl:
        return AppColors.warning;
      case WaypointActionType.land:
        return AppColors.danger;
    }
  }

  String _actionName(WaypointActionType t) {
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

  IconData _actionIcon(WaypointActionType t) {
    switch (t) {
      case WaypointActionType.none:
        return Icons.circle;
      case WaypointActionType.hover:
        return Icons.pause;
      case WaypointActionType.takePhoto:
        return Icons.photo_camera;
      case WaypointActionType.recordVideo:
        return Icons.videocam;
      case WaypointActionType.rtl:
        return Icons.home;
      case WaypointActionType.land:
        return Icons.flight_land;
    }
  }

  // ── Acciones ───────────────────────────────────────────────────────────────

  // Cada toque en el mapa añade un waypoint al final, con la altitud que el
  // usuario configuró en la pantalla de setup.
  // En estos tres métodos siempre se crea una lista NUEVA en vez de modificar la
  // que había: Flutter compara referencias para decidir si tiene que repintar, y
  // mutando la lista en el sitio la pantalla podría no enterarse del cambio.
  void _onMapTap(TapPosition _, LatLng point) {
    final provider = context.read<DronProvider>();
    setState(() {
      _waypoints = [
        ..._waypoints,
        FlightWaypoint(
          lat: point.latitude,
          lon: point.longitude,
          altM: provider.takeoffAltitude,
        ),
      ];
      _hasUnsavedChanges = true;
    });
  }

  void _removeWaypoint(int index) {
    setState(() {
      _waypoints = List.from(_waypoints)..removeAt(index);
      _hasUnsavedChanges = true;
    });
  }

  // Reordenar arrastrando en la lista. El ajuste del índice es obligatorio en
  // ReorderableListView: al mover un elemento hacia abajo, el destino que da
  // Flutter cuenta el hueco que deja el propio elemento, así que sobra uno.
  void _reorderWaypoints(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final item = _waypoints.removeAt(oldIndex);
      _waypoints.insert(newIndex, item);
      _waypoints = List.from(_waypoints);
      _hasUnsavedChanges = true;
    });
  }

  FlightPlan _buildPlan() => FlightPlan(
    id: _planId,
    name: _planName,
    createdAt: widget.existingPlan?.createdAt ?? DateTime.now(),
    waypoints: List.unmodifiable(_waypoints),
  );

  void _savePlan() {
    context.read<DronProvider>().saveFlightPlan(_buildPlan());
    setState(() => _hasUnsavedChanges = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Plan "$_planName" saved'),
        backgroundColor: AppColors.surface,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _uploadMission() async {
    _savePlan();
    await context.read<DronProvider>().uploadMission(_buildPlan());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Uploading mission to drone…'),
        backgroundColor: AppColors.surface,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Diálogos ───────────────────────────────────────────────────────────────

  void _editPlanName() {
    final ctrl = TextEditingController(text: _planName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Plan name',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: _inputDecoration(),
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
              if (ctrl.text.trim().isNotEmpty) {
                setState(() {
                  _planName = ctrl.text.trim();
                  _hasUnsavedChanges = true;
                });
              }
              Navigator.pop(context);
            },
            child: const Text(
              'OK',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _editWaypoint(int index) {
    final wp = _waypoints[index];
    final altCtrl = TextEditingController(text: wp.altM.toStringAsFixed(1));
    final secsCtrl = TextEditingController(
      text: wp.action.seconds.toStringAsFixed(0),
    );
    WaypointAction currentAction = wp.action;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDS) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            'Waypoint ${index + 1}',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Coords
                Text(
                  '${wp.lat.toStringAsFixed(6)}, ${wp.lon.toStringAsFixed(6)}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 14),

                // Altitude
                const Text(
                  'Altitude (m)',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: altCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: _inputDecoration(suffix: 'm'),
                ),
                const SizedBox(height: 14),

                // Action type
                const Text(
                  'Action',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
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
                          color: sel
                              ? AppColors.primary.withValues(alpha: 0.18)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: sel ? AppColors.primary : AppColors.disabled,
                          ),
                        ),
                        child: Text(
                          _actionName(type),
                          style: TextStyle(
                            color: sel
                                ? AppColors.primary
                                : AppColors.textSecondary,
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

                // Seconds (hover / record)
                if (currentAction.type == WaypointActionType.hover ||
                    currentAction.type == WaypointActionType.recordVideo) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Duration (s)',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: secsCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _inputDecoration(suffix: 's'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
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
                  _hasUnsavedChanges = true;
                });
                Navigator.pop(ctx);
              },
              child: const Text(
                'Save',
                style: TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({String? suffix}) => InputDecoration(
    filled: true,
    fillColor: AppColors.background,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.disabled),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.primary),
    ),
    suffixText: suffix,
    suffixStyle: const TextStyle(color: AppColors.textSecondary),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final screenH = MediaQuery.of(context).size.height;
    final totalDist = _calcTotalDist();
    final isMission = provider.isMissionMode;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
        title: isMission
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.route, color: Colors.teal, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'MISSION IN PROGRESS',
                    style: TextStyles.title.copyWith(color: Colors.teal),
                  ),
                ],
              )
            : GestureDetector(
                onTap: _editPlanName,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _planName.toUpperCase(),
                        style: TextStyles.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.edit,
                      size: 13,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
        actions: isMission
            ? const [SizedBox(width: 4)]
            : [
                // Badge de waypoints
                if (_waypoints.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_waypoints.length} WP',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Guardar
                IconButton(
                  icon: Icon(
                    Icons.save_outlined,
                    color: _hasUnsavedChanges
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                  tooltip: 'Save plan',
                  onPressed: _waypoints.isEmpty ? null : _savePlan,
                ),
                // Borrar todo
                if (_waypoints.isNotEmpty)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_sweep,
                      color: AppColors.danger,
                    ),
                    tooltip: 'Clear all waypoints',
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: AppColors.surface,
                        title: const Text(
                          'Clear all waypoints?',
                          style: TextStyle(color: AppColors.textPrimary),
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
                              setState(() {
                                _waypoints = [];
                                _hasUnsavedChanges = true;
                              });
                              Navigator.pop(context);
                            },
                            child: const Text(
                              'Clear',
                              style: TextStyle(color: AppColors.danger),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
              ],
      ),
      // Aquí es donde la pantalla cambia de cara: con la misión en marcha pasa a
      // modo seguimiento; el resto del tiempo, editor.
      body: isMission
          ? _buildMissionTracking(context, provider)
          : _buildEditor(context, provider, totalDist),
    );
  }

  // Editor: mapa arriba para colocar waypoints y lista abajo para reordenarlos y
  // asignarles acciones.
  Widget _buildEditor(
    BuildContext context,
    DronProvider provider,
    double totalDist,
  ) {
    return Column(
      children: [
        // ── Mapa ────────────────────────────────────────────────────────────
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
                        'https://server.arcgisonline.com/ArcGIS/rest/services/'
                        'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                    userAgentPackageName: 'com.example.app',
                  ),
                  // Polyline de la ruta
                  if (_waypoints.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _waypoints
                              .map((w) => LatLng(w.lat, w.lon))
                              .toList(),
                          color: const Color.fromARGB(255, 121, 40, 198),
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
                                    ? AppColors.primary
                                    : i == _waypoints.length - 1
                                    ? AppColors.danger
                                    : AppColors.surface,
                                border: Border.all(
                                  color: AppColors.primary,
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
                                        : AppColors.primary,
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

              // Hint — sin waypoints
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
                        color: AppColors.surface.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Tap on the map to add waypoints',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),

              // Stats overlay
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
                      color: AppColors.surface.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_waypoints.length} WP  ·  ${_fmtDist(totalDist)}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // ── Lista de waypoints ───────────────────────────────────────────
        Expanded(
          flex: 4,
          child: _waypoints.isEmpty
              ? const Center(
                  child: Text(
                    'No waypoints yet',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  itemCount: _waypoints.length,
                  onReorder: _reorderWaypoints,
                  buildDefaultDragHandles: false,
                  itemBuilder: (ctx, i) {
                    final wp = _waypoints[i];
                    return _WaypointItem(
                      key: ValueKey('wp_${wp.lat}_${wp.lon}_$i'),
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

        // ── Botones de acción ────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          color: AppColors.surface,
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.upload),
                  label: const Text(
                    'UPLOAD',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        provider.isConnected && _waypoints.isNotEmpty
                        ? AppColors.primary
                        : AppColors.disabled,
                    foregroundColor: AppColors.textPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: provider.isConnected && _waypoints.isNotEmpty
                      ? _uploadMission
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text(
                    'START',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        provider.isConnected && provider.missionUploaded
                        ? Colors.teal
                        : AppColors.disabled,
                    foregroundColor: AppColors.textPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: provider.isConnected && provider.missionUploaded
                      ? () => provider.startMission()
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Seguimiento: mapa a pantalla completa con el waypoint actual resaltado.
  // El índice activo no lo decide la app: llega de la estación de tierra por
  // MQTT (topicMissionWaypoint) cada vez que el dron alcanza uno.
  Widget _buildMissionTracking(BuildContext context, DronProvider provider) {
    final activeIdx = provider.activeMissionWaypoint;
    final dronePos = (provider.currentLat != 0.0)
        ? LatLng(provider.currentLat, provider.currentLon)
        : null;

    return Stack(
      children: [
        // ── Vídeo oculto ─────────────────────────────────────────
        // Monta el stream del dron fuera de pantalla (1×1) para que exista un
        // elemento <video> en el DOM: lo necesitan capturePhoto/startRecording
        // cuando un waypoint tiene acción de foto/vídeo (aquí la pantalla es mapa).
        if (provider.remoteStream != null)
          Offstage(
            offstage: true,
            child: SizedBox(
              width: 1,
              height: 1,
              child: DroneVideoView(stream: provider.remoteStream!),
            ),
          ),
        // ── Mapa fullscreen ──────────────────────────────────────
        // RepaintBoundary: aísla el repintado del mapa del resto del árbol para que
        // el rebuild de telemetría (10Hz) no fuerce repintar overlays y el timer de
        // interpolación del icono (16ms) corra fluido.
        RepaintBoundary(
          child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: dronePos ?? _mapCenter,
            initialZoom: 17,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
              scrollWheelVelocity: 0.005,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://server.arcgisonline.com/ArcGIS/rest/services/'
                  'World_Imagery/MapServer/tile/{z}/{y}/{x}',
              userAgentPackageName: 'com.example.app',
            ),
            // Ruta completa en gris tenue
            if (_waypoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _waypoints
                        .map((w) => LatLng(w.lat, w.lon))
                        .toList(),
                    color: Colors.white24,
                    strokeWidth: 2.0,
                  ),
                ],
              ),
            // Segmento ya recorrido en color primario
            if (activeIdx > 0 && activeIdx < _waypoints.length)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _waypoints
                        .sublist(0, activeIdx + 1)
                        .map((w) => LatLng(w.lat, w.lon))
                        .toList(),
                    color: AppColors.primary,
                    strokeWidth: 3.0,
                  ),
                ],
              ),
            // Waypoints — el activo brilla y el dron se muestra con su icono y orientación real
            MarkerLayer(
              markers: [
                for (int i = 0; i < _waypoints.length; i++)
                  Marker(
                    point: LatLng(_waypoints[i].lat, _waypoints[i].lon),
                    width: i == activeIdx ? 38 : 28,
                    height: i == activeIdx ? 38 : 28,
                    child: Stack(
                      clipBehavior: Clip.none,
                      fit: StackFit.expand,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < activeIdx
                                ? AppColors.disabled
                                : i == activeIdx
                                ? Colors.teal
                                : AppColors.surface,
                            border: Border.all(
                              color: i == activeIdx
                                  ? Colors.teal
                                  : AppColors.primary,
                              width: i == activeIdx ? 3 : 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                color: i <= activeIdx
                                    ? Colors.white
                                    : AppColors.primary,
                                fontSize: i == activeIdx ? 13 : 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        // Badge de acción del waypoint (oculto si es 'none')
                        if (_waypoints[i].action.type !=
                            WaypointActionType.none)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              width: 16,
                              height: 16,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _actionColor(_waypoints[i].action.type),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1,
                                ),
                              ),
                              child: Icon(
                                _actionIcon(_waypoints[i].action.type),
                                size: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            // Icono dron en tiempo real — posición/orientación interpoladas para
            // un movimiento fluido independiente de la tasa de telemetría.
            if (dronePos != null)
              ValueListenableBuilder<LatLng>(
                valueListenable: provider.droneRenderPos,
                builder: (_, renderPos, _) => ValueListenableBuilder<double>(
                  valueListenable: provider.droneRenderHeading,
                  builder: (_, renderHeading, _) => MarkerLayer(
                    markers: [
                      Marker(
                        point: renderPos,
                        width: 36,
                        height: 36,
                        child: Transform.rotate(
                          angle: renderHeading * pi / 180,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              RepaintBoundary(
                                child: Image.asset(
                                  'assets/images/drone_icon.png',
                                  width: 32,
                                  height: 32,
                                ),
                              ),
                              const Positioned(
                                top: -14,
                                child: Icon(
                                  Icons.arrow_upward,
                                  color: Colors.greenAccent,
                                  size: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          ),
        ),

        // ── Overlay progreso WP (top-left) ───────────────────────
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.teal),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.route, color: Colors.teal, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'WP ${activeIdx + 1} / ${_waypoints.length}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                // Acción del waypoint activo (oculta si es 'none')
                if (activeIdx >= 0 &&
                    activeIdx < _waypoints.length &&
                    _waypoints[activeIdx].action.type !=
                        WaypointActionType.none) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _actionColor(_waypoints[activeIdx].action.type)
                          .withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _actionColor(_waypoints[activeIdx].action.type),
                      ),
                    ),
                    child: Text(
                      _waypoints[activeIdx].action.label,
                      style: TextStyle(
                        color: _actionColor(_waypoints[activeIdx].action.type),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Telemetría rápida (top-right) ────────────────────────
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.disabled),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${provider.currentAlt.toStringAsFixed(1)} m',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${provider.currentSpeed.toStringAsFixed(1)} m/s',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                Text(
                  'BAT ${provider.currentBat.toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: provider.currentBat < 20
                        ? AppColors.danger
                        : provider.currentBat < 50
                        ? AppColors.warning
                        : AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Botón de STOP / START (bottom) ─────────────────────────
        Positioned(
          bottom: 24,
          left: 16,
          right: 16,
          child: provider.isFlying
              ? SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text(
                      'STOP MISSION',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => context.read<DronProvider>().rtl(),
                  ),
                )
              : SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text(
                      'START MISSION',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () =>
                        context.read<DronProvider>().startMission(),
                  ),
                ),
        ),
      ],
    );
  }
}

// ─── WAYPOINT LIST ITEM ───────────────────────────────────────────────────────

class _WaypointItem extends StatelessWidget {
  final int index;
  final FlightWaypoint waypoint;
  final Color actionColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _WaypointItem({
    required super.key,
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
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.drag_handle,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            // Número
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary,
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
            // Coords + alt
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${waypoint.lat.toStringAsFixed(5)}, '
                    '${waypoint.lon.toStringAsFixed(5)}',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${waypoint.altM.toStringAsFixed(1)} m alt',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            // Action chip
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
            // Borrar
            GestureDetector(
              onTap: onDelete,
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
      ),
    );
  }
}
