import 'package:flutter/material.dart';

// ============================================================
// DEMO: WIDGETS Y BOTONES DE EZDRONE
// ============================================================
//
// Esta app demuestra los tipos de botones y widgets interactivos
// utilizados en EZDrone, agrupados por categoría.
//
// WIDGETS DEMOSTRADOS:
//
// 1. ElevatedButton.icon — Botones de acción principal
//    Usados en: SetupScreen (CONNECT, START FLIGHT, DISCONNECT)
//               FlightScreen (ARM, TAKEOFF, LAND, RTL, DISCONNECT)
//    Estados: enabled / disabled
//    Colores semáforo: primary (verde), warning (naranja), danger (rojo)
//
// 2. GestureDetector + AnimatedContainer — Botón táctico con borde
//    Usados en: HudButton (Tello), FlipBtn, ModeChip, ConnectionChip
//    Comportamiento: borde coloreado, fondo semitransparente activo,
//    animación de 150ms en press y en estado active/inactive
//
// 3. GestureDetector + Container — Botón icono compacto
//    Usados en: swap mapa/cámara, captura foto, grabar, switch cámara
//    Sin animación explícita; color de fondo y borde indican estado
//
// 4. GestureDetector (onLongPressStart/End + onTapDown/Up) — Presión continua
//    Usado en: buildAltButton (IMU screen) para subir/bajar altitud
//    La acción se activa mientras el dedo está presionado
//
// 5. Slider — Control de zoom de cámara
//    Usado en: FlightScreen, zona lateral (portrait) y horizontal (landscape)
//    Rango 1.0–5.0, 8 divisiones, coloreado con AppColors.primary
//
// 6. DropdownButton — Selector de modo de detección YOLO
//    Usado en: DetectionDropdown dentro de FlightScreen (sobre el vídeo)
//    Fondo oscuro, icono pequeño, sin subrayado
//
// 7. ModeChip / ConnectionChip — Selector exclusivo tipo chip
//    Usados en: ModeSelector (Classic/Voice/IMU) y DroneConnectionModeSelector
//    AnimatedContainer 200ms; borde de 2px del color del modo cuando seleccionado
//
// 8. ModalBottomSheet + DraggableScrollableSheet — Hoja de ayuda arrastrable
//    Usados en: showHelpSheet() (SetupScreen), ModeSelectorSheet (TelloFlightScreen)
//    showModalBottomSheet con isScrollControlled; tamaños 0.75/0.4/0.92
//
// 9. AlertDialog — Diálogo de confirmación
//    Usado en: borrar waypoints (FlightPlanScreen), error de conexión (SetupScreen)
//    backgroundColor = surface; acción Cancel + acción destructiva (danger)
//
// 10. ReorderableListView — Lista reordenable con drag handle
//    Usados en: waypoints (FlightPlanScreen) y registros (FlightLogScreen)
//    buildDefaultDragHandles: false + ReorderableDragStartListener manual
//
// PALETA DE COLORES (AppColors):
//   background  #1E1E2E  — fondo general
//   surface     #2A2A3E  — tarjetas y barras
//   primary     #4CAF50  — verde (conectado, TAKEOFF)
//   warning     #FF9800  — naranja (ARM, LAND, RTL)
//   danger      #C62828  — rojo (armado, DISCONNECT)
//   textPrimary #FFFFFF
//   textSecondary #B0B0C0
//   disabled    #555566
// ============================================================

// ---- COLORES ----
class AppColors {
  static const Color background = Color(0xFF1E1E2E);
  static const Color surface = Color(0xFF2A2A3E);
  static const Color primary = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color danger = Color(0xFFC62828);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0C0);
  static const Color disabled = Color(0xFF555566);
}

void main() {
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: WidgetsDemo()),
  );
}

// ============================================================
// PANTALLA PRINCIPAL
// ============================================================
class WidgetsDemo extends StatefulWidget {
  const WidgetsDemo({super.key});

  @override
  State<WidgetsDemo> createState() => _WidgetsDemoState();
}

class _WidgetsDemoState extends State<WidgetsDemo> {
  // --- Estado de los widgets interactivos ---

  // ElevatedButton: simulamos estado de vuelo
  bool _isConnected = false;
  bool _isArmed = false;
  bool _isFlying = false;

  // GestureDetector táctico (HudButton)
  bool _hudActive = false;

  // Botón icono compacto
  bool _isRecording = false;

  // Presión continua (altitud)
  bool _altUpPressed = false;
  bool _altDownPressed = false;

  // Slider (zoom)
  double _zoom = 1.0;

  // Dropdown (detección YOLO)
  String _detectionMode = 'Todos';

  // Chips de modo
  String _controlMode = 'Classic';
  String _connMode = 'ArduPilot';

  // Lista reordenable (widget 10)
  final List<String> _reorderItems = [
    'WP 1 — 41.27650, 1.98880',
    'WP 2 — 41.27700, 1.98920',
    'WP 3 — 41.27620, 1.98850',
    'WP 4 — 41.27580, 1.98810',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'WIDGETS',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 1. ElevatedButton.icon ----
            _sectionHeader(
              '1. ElevatedButton.icon',
              '— Botones de acción principal',
            ),
            _codeNote(
              'Usado en: SetupScreen (CONNECT, START FLIGHT) y FlightScreen (ARM, TAKEOFF, LAND, RTL, DISCONNECT).\n'
              'El color cambia según el estado del vuelo. onPressed = null, botón deshabilitado automáticamente.',
            ),
            const SizedBox(height: 12),
            // Fila ARM/TAKEOFF/LAND/RTL/DISCONNECT como en FlightScreen
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.power_settings_new, size: 16),
                    label: const Text(
                      'ARM',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      // Verde si no armado, rojo si armado (igual que EZDrone)
                      backgroundColor: _isArmed
                          ? AppColors.danger
                          : AppColors.warning,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    // Solo habilitado si conectado, no armado y no volando
                    onPressed: !_isConnected || _isArmed || _isFlying
                        ? null
                        : () => setState(() => _isArmed = true),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.flight_takeoff, size: 16),
                    label: const Text(
                      'TAKEOFF',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: !_isConnected || !_isArmed || _isFlying
                        ? null
                        : () => setState(() => _isFlying = true),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.flight_land, size: 16),
                    label: const Text(
                      'LAND',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.warning,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: !_isFlying
                        ? null
                        : () => setState(() {
                            _isFlying = false;
                            _isArmed = false;
                          }),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text(
                      'DISC',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      disabledBackgroundColor: AppColors.danger,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: !_isConnected || _isArmed || _isFlying
                        ? null
                        : () => setState(() => _isConnected = false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // CONNECT / START FLIGHT (ancho completo, como SetupScreen)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.link),
                label: Text(
                  _isConnected ? 'CONNECTED ✓' : 'CONNECT',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isConnected
                      ? AppColors.disabled
                      : AppColors.primary,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isConnected
                    ? null
                    : () => setState(() => _isConnected = true),
              ),
            ),
            const SizedBox(height: 24),

            // ---- 2. GestureDetector + AnimatedContainer (HudButton táctico) ----
            _sectionHeader(
              '2. GestureDetector + AnimatedContainer',
              '— Botón táctico con borde',
            ),
            _codeNote(
              'Usado en: HudButton (TelloFlightScreen), FlipBtn, ModeOption.\n'
              'AnimatedContainer con duration 150ms anima el color de fondo y el grosor del borde.\n'
              'active: fondo semitransparente del color + borde de 1.5px; inactivo: fondo oscuro + borde disabled.',
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _HudButton(
                  icon: Icons.flight_takeoff,
                  label: 'TAKEOFF',
                  color: AppColors.primary,
                  enabled: true,
                  active: _hudActive,
                  onTap: () => setState(() => _hudActive = !_hudActive),
                ),
                const SizedBox(width: 12),
                _HudButton(
                  icon: Icons.flight_land,
                  label: 'LAND',
                  color: AppColors.warning,
                  enabled: true,
                  active: false,
                  onTap: () {},
                ),
                const SizedBox(width: 12),
                _HudButton(
                  icon: Icons.link_off,
                  label: 'DISC',
                  color: AppColors.danger,
                  enabled: false, // deshabilitado, icono y texto en disabled
                  active: false,
                  onTap: () {},
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ---- 3. GestureDetector + Container (icono compacto) ----
            _sectionHeader(
              '3. GestureDetector + Container',
              '— Botón icono compacto',
            ),
            _codeNote(
              'Usado en: swap mapa/cámara, captura foto, grabar vídeo, cambiar cámara (FlightScreen).\n'
              'Sin AnimatedContainer; el color de fondo y el borde reflejan el estado directamente.\n'
              'El botón REC cambia a danger cuando _isRecording = true.',
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Captura foto
                _IconCompactButton(
                  icon: Icons.camera_alt,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {},
                ),
                const SizedBox(width: 10),
                // Grabar (toggle)
                _IconCompactButton(
                  icon: _isRecording
                      ? Icons.stop_circle
                      : Icons.fiber_manual_record,
                  active: _isRecording,
                  activeColor: AppColors.danger,
                  onTap: () => setState(() => _isRecording = !_isRecording),
                ),
                const SizedBox(width: 10),
                // Switch cámara
                _IconCompactButton(
                  icon: Icons.cameraswitch,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {},
                ),
                const SizedBox(width: 10),
                // Swap mapa/cámara
                _IconCompactButton(
                  icon: Icons.map,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {},
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ---- 4. Presión continua (altitud) ----
            _sectionHeader(
              '4. GestureDetector (onLongPress + onTapDown)',
              '— Presión continua',
            ),
            _codeNote(
              'Usado en: buildAltButton (ImuFlightScreen) para subir/bajar altitud.\n'
              'onLongPressStart / onTapDown, activa el eje lY del joystick (+1.0 o -1.0).\n'
              'onLongPressEnd / onTapUp / onTapCancel, devuelve lY a 0.0.\n'
              'El borde cambia a primary (subir) o warning (bajar) mientras se mantiene presionado.',
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AltButton(
                  up: true,
                  pressed: _altUpPressed,
                  onPressStart: () => setState(() => _altUpPressed = true),
                  onPressEnd: () => setState(() => _altUpPressed = false),
                ),
                const SizedBox(width: 20),
                _AltButton(
                  up: false,
                  pressed: _altDownPressed,
                  onPressStart: () => setState(() => _altDownPressed = true),
                  onPressEnd: () => setState(() => _altDownPressed = false),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ---- 5. Slider (zoom) ----
            _sectionHeader('5. Slider', '— Control de zoom de cámara'),
            _codeNote(
              'Usado en: FlightScreen, zona lateral izquierda en portrait y horizontal en landscape.\n'
              'Rango 1.0 - 5.0, 8 divisiones. trackHeight 2, thumbRadius 6, overlayRadius 10.\n',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.zoom_out,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                        activeTrackColor: AppColors.primary,
                        inactiveTrackColor: AppColors.disabled,
                        thumbColor: AppColors.primary,
                        overlayColor: AppColors.primary,
                      ),
                      child: Slider(
                        value: _zoom,
                        min: 1.0,
                        max: 5.0,
                        divisions: 8,
                        // onChanged actualiza el estado con el nuevo valor
                        onChanged: (v) => setState(() => _zoom = v),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.zoom_in,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_zoom.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ---- 6. DropdownButton ----
            _sectionHeader(
              '6. DropdownButton',
              '— Selector de modo de detección YOLO',
            ),
            _codeNote(
              'Usado en: DetectionDropdown (FlightScreen, superpuesto sobre el vídeo WebRTC).\n'
              'DropdownButtonHideUnderline elimina la línea inferior. dropdownColor = surface.\n'
              'Cada ítem combina un Icon pequeño (13px) con un Text.',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.disabled),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _detectionMode,
                  isDense: true,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                  icon: const Icon(
                    Icons.arrow_drop_down,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Todos',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.select_all,
                            color: AppColors.primary,
                            size: 13,
                          ),
                          SizedBox(width: 5),
                          Text('Todos'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Personas',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person,
                            color: AppColors.primary,
                            size: 13,
                          ),
                          SizedBox(width: 5),
                          Text('Personas'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Ninguno',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.visibility_off,
                            color: AppColors.disabled,
                            size: 13,
                          ),
                          SizedBox(width: 5),
                          Text('Ninguno'),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _detectionMode = v);
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ---- 7. ModeChip / ConnectionChip ----
            _sectionHeader(
              '7. ModeChip / ConnectionChip',
              '— Selector exclusivo tipo chip',
            ),
            _codeNote(
              'Usado en: ModeSelector (Classic/Voice/IMU) y DroneConnectionModeSelector (ArduPilot/SITL/Tello).\n'
              'AnimatedContainer con duration 200ms. Seleccionado: borde 2px del color del modo + texto bold.\n'
              'No seleccionado: borde disabled 1px + texto textSecondary.',
            ),
            const SizedBox(height: 10),
            // Control mode chips
            const Text(
              'CONTROL MODE',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _ModeChip(
                  label: 'Classic',
                  icon: Icons.sports_esports,
                  color: AppColors.primary,
                  selected: _controlMode == 'Classic',
                  onTap: () => setState(() => _controlMode = 'Classic'),
                ),
                _ModeChip(
                  label: 'Voice',
                  icon: Icons.mic,
                  color: Colors.teal,
                  selected: _controlMode == 'Voice',
                  onTap: () => setState(() => _controlMode = 'Voice'),
                ),
                _ModeChip(
                  label: 'IMU',
                  icon: Icons.sensors,
                  color: Colors.deepPurple,
                  selected: _controlMode == 'IMU',
                  onTap: () => setState(() => _controlMode = 'IMU'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Connection mode chips
            const Text(
              'DRONE MODE',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _ModeChip(
                  label: 'ArduPilot',
                  icon: Icons.developer_board,
                  color: AppColors.primary,
                  selected: _connMode == 'ArduPilot',
                  onTap: () => setState(() => _connMode = 'ArduPilot'),
                ),
                _ModeChip(
                  label: 'SITL',
                  icon: Icons.computer,
                  color: Colors.orange,
                  selected: _connMode == 'SITL',
                  onTap: () => setState(() => _connMode = 'SITL'),
                ),
                _ModeChip(
                  label: 'Tello',
                  icon: Icons.flight,
                  color: Colors.lightBlue,
                  selected: _connMode == 'Tello',
                  onTap: () => setState(() => _connMode = 'Tello'),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ---- 8. ModalBottomSheet + DraggableScrollableSheet ----
            _sectionHeader(
              '8. ModalBottomSheet + DraggableScrollableSheet',
              '— Hoja de ayuda arrastrable',
            ),
            _codeNote(
              'Usado en: showHelpSheet() (SetupScreen), ModeSelectorSheet (TelloFlightScreen).\n'
              'showModalBottomSheet con isScrollControlled: true permite ocupar hasta el 92% de pantalla.\n'
              'DraggableScrollableSheet controla el tamaño inicial (0.75), mínimo (0.4) y máximo (0.92).\n'
              'El contenido interior usa SingleChildScrollView para scroll independiente.',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.help_outline),
                label: const Text(
                  'SHOW HELP SHEET',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _showHelpSheet(context),
              ),
            ),
            const SizedBox(height: 24),

            // ---- 9. AlertDialog ----
            _sectionHeader('9. AlertDialog', '— Diálogo de confirmación'),
            _codeNote(
              'Usado en: confirmación de borrar waypoints (FlightPlanScreen) y error de conexión (SetupScreen).\n'
              'backgroundColor = surface para mantener la paleta oscura.\n'
              'Acciones: TextButton Cancel (textSecondary) + TextButton destructivo (danger o primary).',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.delete_sweep),
                label: const Text(
                  'SHOW ALERT DIALOG',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _showAlertDialog(context),
              ),
            ),
            const SizedBox(height: 24),

            // ---- 10. ReorderableListView ----
            _sectionHeader(
              '10. ReorderableListView',
              '— Lista reordenable con drag handle',
            ),
            _codeNote(
              'Usado en: lista de waypoints (FlightPlanScreen) y registros de vuelo (FlightLogScreen).\n'
              'ReorderableListView.builder con buildDefaultDragHandles: false.\n'
              'Cada ítem usa ReorderableDragStartListener como handle manual con su índice.\n'
              'onReorder: removeAt(oldIndex) + insert(newIndex, item).',
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: _ReorderableDemo(items: _reorderItems),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---------- Métodos para widgets 8 y 9 ----------

  void _showHelpSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              const Row(
                children: [
                  Icon(Icons.flight, color: AppColors.primary, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'EZDrone — How to fly',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const _HelpSection(
                icon: Icons.sports_esports,
                title: 'Classic Joystick',
                color: AppColors.primary,
                items: [
                  _HelpItem(
                    Icons.adjust,
                    'Left stick — Throttle (↑↓) and Yaw (←→)',
                  ),
                  _HelpItem(
                    Icons.open_with,
                    'Right stick — Pitch (fwd/back) and Roll (←→)',
                  ),
                  _HelpItem(
                    Icons.swap_horiz,
                    'Swap button — Toggle map / camera view',
                  ),
                  _HelpItem(
                    Icons.videocam,
                    'Camera on: 📷 capture photo · ⏺ record video · 🔄 switch camera',
                  ),
                  _HelpItem(
                    Icons.zoom_in,
                    'Zoom bar (×1–×5) — available in camera view only',
                  ),
                  _HelpItem(
                    Icons.search,
                    'YOLO detection — All objects / Persons only / Off (camera view)',
                  ),
                  _HelpItem(
                    Icons.check_circle,
                    'Flow: CONNECT → ARM → TAKEOFF → fly → LAND or RTL → DISCONNECT',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _HelpSection(
                icon: Icons.sensors,
                title: 'IMU / Gyroscope',
                color: Colors.deepPurple,
                items: const [
                  _HelpItem(
                    Icons.phone_android,
                    'NORMAL — Tilt fwd/back/left/right to move (portrait)',
                  ),
                  _HelpItem(
                    Icons.screen_rotation,
                    'VOLANTE — Hold flat, tilt like a steering wheel (landscape)',
                  ),
                  _HelpItem(
                    Icons.height,
                    '▲▼ buttons — Hold to climb or descend',
                  ),
                  _HelpItem(
                    Icons.sensors,
                    'Tap START to activate IMU, STOP to deactivate',
                  ),
                  _HelpItem(
                    Icons.warning_amber,
                    'Dead zone ±5–15° (fwd) / ±10° (lateral) ignored',
                  ),
                  _HelpItem(Icons.info_outline, 'Not available for Tello'),
                ],
              ),
              const SizedBox(height: 16),
              _HelpSection(
                icon: Icons.mic,
                title: 'Voice Control (es-ES)',
                color: Colors.teal,
                items: const [
                  _HelpItem(
                    Icons.touch_app,
                    'First tap 🎤 — grants microphone permission in the browser',
                  ),
                  _HelpItem(Icons.mic, 'Hold 🎤 → speak → release → executes'),
                  _HelpItem(
                    Icons.record_voice_over,
                    'armar · despegar · aterrizar · para / stop',
                  ),
                  _HelpItem(
                    Icons.record_voice_over,
                    'adelante · atrás · derecha · izquierda',
                  ),
                  _HelpItem(
                    Icons.record_voice_over,
                    'subir · bajar · volver a despegue (RTL)',
                  ),
                  _HelpItem(Icons.info_outline, 'Not available for Tello'),
                ],
              ),
              const SizedBox(height: 16),
              const _HelpSection(
                icon: Icons.flight,
                title: 'Tello (DJI)',
                color: Colors.lightBlue,
                items: [
                  _HelpItem(
                    Icons.wifi,
                    'Connect your device to the Tello Wi-Fi before launching the app',
                  ),
                  _HelpItem(
                    Icons.sports_esports,
                    'Dual joystick — left: Throttle/Yaw · right: Pitch/Roll',
                  ),
                  _HelpItem(
                    Icons.flight_takeoff,
                    'TAKEOFF — takes off automatically (~50 cm), no ARM step required',
                  ),
                  _HelpItem(
                    Icons.flight_land,
                    'LAND — smooth descent and motor stop',
                  ),
                  _HelpItem(
                    Icons.videocam,
                    'Camera on: 📷 capture photo · ⏺ record video',
                  ),
                  _HelpItem(
                    Icons.tune,
                    'MODES — opens the Flip, Follow and Orbit panel',
                  ),
                  _HelpItem(
                    Icons.flip_camera_android,
                    'Flip: tap a direction arrow while flying to execute the flip',
                  ),
                  _HelpItem(
                    Icons.directions_run,
                    'Follow: activates person-tracking mode (tap STOP to deactivate)',
                  ),
                  _HelpItem(
                    Icons.rotate_right,
                    'Orbit: orbits around a person — adjust radius with slider (30–200 cm)',
                  ),
                  _HelpItem(
                    Icons.warning_amber,
                    'Voice and IMU modes are not available for Tello',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _HelpSection(
                icon: Icons.edit_location_alt_outlined,
                title: 'Flight Planner',
                color: AppColors.primary,
                items: [
                  _HelpItem(
                    Icons.map,
                    'Tap the map to add waypoints — numbered in insertion order',
                  ),
                  _HelpItem(
                    Icons.touch_app,
                    'Tap a waypoint on the map or list to edit its altitude and action',
                  ),
                  _HelpItem(
                    Icons.drag_handle,
                    'Drag the ≡ handle in the list to reorder waypoints',
                  ),
                  _HelpItem(
                    Icons.bolt,
                    'Actions per waypoint: None · Hover · Photo · Record · RTL · Land',
                  ),
                  _HelpItem(
                    Icons.save_outlined,
                    'Save plan locally with 💾 — persists across sessions',
                  ),
                  _HelpItem(
                    Icons.upload,
                    'UPLOAD — sends the mission to the drone (active connection required)',
                  ),
                  _HelpItem(
                    Icons.play_arrow,
                    'START — begins autonomous mission once uploaded to the drone',
                  ),
                  _HelpItem(
                    Icons.download_outlined,
                    'Download plan as a .waypoints file compatible with Mission Planner',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _HelpSection(
                icon: Icons.history,
                title: 'Flight Log',
                color: AppColors.primary,
                items: [
                  _HelpItem(
                    Icons.auto_graph,
                    'Every completed or interrupted flight is recorded automatically',
                  ),
                  _HelpItem(
                    Icons.map_outlined,
                    'Tap a session to view its trail on an interactive map with a playback slider',
                  ),
                  _HelpItem(
                    Icons.speed,
                    'Stats: duration · distance · max altitude · altitude gain · max speed · min battery',
                  ),
                  _HelpItem(
                    Icons.download,
                    'Download telemetry data as a CSV file',
                  ),
                  _HelpItem(
                    Icons.delete_sweep,
                    'Delete sessions individually or clear all at once',
                  ),
                ],
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Got it',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAlertDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear all waypoints?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will remove all waypoints from the current plan. This action cannot be undone.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
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
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Clear',
              style: TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Cabecera de sección
  Widget _sectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        Text(
          subtitle,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Container(height: 1, color: AppColors.disabled),
        const SizedBox(height: 8),
      ],
    );
  }

  // Nota de código / descripción técnica
  Widget _codeNote(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.disabled),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          height: 1.5,
        ),
      ),
    );
  }
}

// ============================================================
// WIDGETS REUTILIZABLES (réplicas exactas de EZDrone)
// ============================================================

// ---- Widget 2: HudButton (GestureDetector + AnimatedContainer) ----
class _HudButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final bool active;
  final VoidCallback onTap;

  const _HudButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          // Fondo: activo, color semitransparente; habilitado, oscuro; deshabilitado, más oscuro
          color: active
              ? color.withValues(alpha: 0.25)
              : enabled
              ? Colors.black54
              : Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.8) : AppColors.disabled,
            width: active ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: enabled ? color : AppColors.disabled, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: enabled ? color : AppColors.disabled,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Widget 3: Botón icono compacto (GestureDetector + Container) ----
class _IconCompactButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _IconCompactButton({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.2) : Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? activeColor : AppColors.disabled),
        ),
        child: Icon(icon, color: AppColors.textPrimary, size: 18),
      ),
    );
  }
}

// ---- Widget 4: Botón de altitud (presión continua) ----
class _AltButton extends StatelessWidget {
  final bool up;
  final bool pressed;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  const _AltButton({
    required this.up,
    required this.pressed,
    required this.onPressStart,
    required this.onPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final Color borderColor = up ? AppColors.primary : AppColors.warning;
    return GestureDetector(
      // onLongPressStart activa el comando continuamente
      onLongPressStart: (_) => onPressStart(),
      onLongPressEnd: (_) => onPressEnd(),
      // onTapDown / onTapUp para pulsaciones cortas
      onTapDown: (_) => onPressStart(),
      onTapUp: (_) => onPressEnd(),
      onTapCancel: onPressEnd,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: pressed ? Colors.black54 : Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: pressed ? borderColor : AppColors.disabled),
        ),
        child: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          color: pressed ? borderColor : AppColors.disabled,
          size: 28,
        ),
      ),
    );
  }
}

// ---- Widget 7: ModeChip / ConnectionChip ----
class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : AppColors.disabled,
            width: selected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// WIDGETS AUXILIARES — Sección 8 (HelpSheet) y 10 (ReorderableList)
// ============================================================

// ---- _HelpSection y _HelpItem (widget 8) ----
class _HelpSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final List<_HelpItem> items;

  const _HelpSection({
    required this.icon,
    required this.title,
    required this.color,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...items,
        ],
      ),
    );
  }
}

class _HelpItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HelpItem(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- _ReorderableDemo (widget 10) ----
class _ReorderableDemo extends StatefulWidget {
  final List<String> items;
  const _ReorderableDemo({required this.items});

  @override
  State<_ReorderableDemo> createState() => _ReorderableDemoState();
}

class _ReorderableDemoState extends State<_ReorderableDemo> {
  late List<String> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      itemCount: _items.length,
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final item = _items.removeAt(oldIndex);
          _items.insert(newIndex, item);
        });
      },
      itemBuilder: (ctx, i) => Container(
        key: ValueKey(_items[i]),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: i,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.drag_handle,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary,
              ),
              child: Center(
                child: Text(
                  '${i + 1}',
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
              child: Text(
                _items[i],
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _items.removeAt(i)),
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
