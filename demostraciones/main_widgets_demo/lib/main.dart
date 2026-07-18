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
//    Estados: enabled / disabled
//    Colores semáforo: primary (verde), warning (naranja), danger (rojo)
//
// 2. GestureDetector + AnimatedContainer — Botón con borde
//    Comportamiento: borde coloreado, fondo semitransparente activo,
//    animación de 150ms en press y en estado active/inactive
//
// 3. GestureDetector + Container — Botón icono compacto
//    Sin animación explícita; color de fondo y borde indican estado
//
// 4. GestureDetector (onLongPressStart/End + onTapDown/Up) — Presión continua
//    La acción se activa mientras el dedo está presionado
//
// 5. Slider — Control de zoom de cámara
//    Rango 1.0–5.0, 8 divisiones, coloreado con AppColors.primary
//
// 6. DropdownButton — Selector de modo de detección YOLO
//    Fondo oscuro, icono pequeño, sin subrayado
//
// 7. ModeChip / ConnectionChip — Selector exclusivo tipo chip
//    AnimatedContainer 200ms; borde de 2px del color del modo cuando seleccionado
//
// 8. ModalBottomSheet + DraggableScrollableSheet — Hoja de ayuda arrastrable
//    showModalBottomSheet con isScrollControlled; tamaños 0.75/0.4/0.92
//
// 9. AlertDialog — Diálogo de confirmación
//    backgroundColor = surface; acción Cancel + acción destructiva (danger)
//
// 10. ReorderableListView — Lista reordenable con drag handle
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

class WidgetsDemo extends StatefulWidget {
  const WidgetsDemo({super.key});

  @override
  State<WidgetsDemo> createState() => _WidgetsDemoState();
}

class _WidgetsDemoState extends State<WidgetsDemo> {

//--------------- variables de estado ----------------- 

  // Simulación de estado de conexión y vuelo para ElevatedButton.icon (widget 1)
  bool _isConnected = false;
  bool _isArmed = false;
  bool _isFlying = false;

  // Simulación de estado de HUD (widget 2)
  bool _hudActive = false;

  // Botón icono compacto (widget 3)
  bool _isRecording = false;

  // Presión continua (widget 4)
  bool _altUpPressed = false;
  bool _altDownPressed = false;

  // Slider para simular zoom de cámara (widget 5)
  double _zoom = 1.0;

  // Dropdown para simular tipo de detección YOLO (widget 6)
  String _detectionMode = 'Todos';

  // Chips de modo de control y modo de conexión (widget 7)
  String _controlMode = 'Classic';
  String _connMode = 'ArduPilot';

  // Lista reordenable (widget 10)
  final List<String> _reorderItems = [
    'WP 1 — 41.27650, 1.98880',
    'WP 2 — 41.27700, 1.98920',
    'WP 3 — 41.27620, 1.98850',
    'WP 4 — 41.27580, 1.98810',
  ];


  // -------------- PANTALLA PRINCIPAL -----------------
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


            // ---- 1. ElevatedButton.icon ----------------------------------------------------------------------------------
            _sectionHeader(
              '1. ElevatedButton.icon',
              '— Botones de acción principal',
            ),
            _codeNote(
              'Estados posibles: enabled / disabled.\n'
            ),
            const SizedBox(height: 12),
            // Fila ARM/TAKEOFF/LAND/RTL/DISCONNECT  para simular flujo de vuelo
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(                                                    // ELEVATED BUTTON ARM
                    icon: const Icon(Icons.power_settings_new, size: 16),                        // ICONO
                    label: const Text(
                      'ARM',                                                                     // TEXTO
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(                                              // ESTILO 
                      // Verde si no armado, rojo si armado 
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

                    onPressed: !_isConnected || _isArmed || _isFlying                              // ACCIÓN

                    // Si no está conectado, o ya está armado, o está volando, el botón se deshabilita (null)
                        ? null  
                        : () => setState(() => _isArmed = true),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded( 
                  child: ElevatedButton.icon(                                                      // ELEVATED BUTTON TAKEOFF
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
                    onPressed: !_isConnected || !_isArmed || _isFlying    // si no está conectado, o no está armado, o ya está volando, el botón se deshabilita (null)
                        ? null
                        : () => setState(() => _isFlying = true),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(                                                          // ELEVATED BUTTON LAND
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
                    onPressed: !_isFlying   // si no está volando, el botón se deshabilita (null)
                        ? null
                        : () => setState(() {
                            _isFlying = false;
                            _isArmed = false;
                          }),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ElevatedButton.icon(                                                              // ELEVATED BUTTON DISC
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
                    onPressed: !_isConnected || _isArmed || _isFlying   // si no está conectado, o está armado, o está volando, el botón se deshabilita (null)
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
              child: ElevatedButton.icon(                                                                  // ELEVATED BUTTON CONNECT  
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
                onPressed: _isConnected   // si ya está conectado, el botón se deshabilita (null)
                    ? null
                    : () => setState(() => _isConnected = true),
              ),
            ),


            const SizedBox(height: 24),



            // ---- 2. GestureDetector + AnimatedContainer ------------------------------------------------------------------------------------------
            _sectionHeader(
              '2. GestureDetector + AnimatedContainer',
              '— Botón táctico con borde',
            ),
            _codeNote(
              'AnimatedContainer con duration 150ms. Fondo semitransparente y borde coloreado cuando está activo.\n'
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _HudButton(                                     // = GestureDetector + AnimatedContainer (Construido en el widget _HudButton)
                  icon: Icons.flight_takeoff,
                  label: 'TAKEOFF',
                  color: AppColors.primary,
                  enabled: true,
                  active: _hudActive,
                  onTap: () => setState(() => _hudActive = !_hudActive),  // onTap alterna el estado activo del botón
                ),
                const SizedBox(width: 12),
                _HudButton(
                  icon: Icons.flight_land,
                  label: 'LAND',
                  color: AppColors.warning,
                  enabled: true,
                  active: false,
                  onTap: () {}, // onTap no hace nada, pero el botón está habilitado
                ),
                const SizedBox(width: 12),
                _HudButton(
                  icon: Icons.link_off,
                  label: 'DISC',
                  color: AppColors.danger,
                  enabled: false, // deshabilitado, icono y texto en disabled
                  active: false,
                  onTap: () {},   // onTap no hace nada, pero el botón está deshabilitado
                ),
              ],
            ),


            const SizedBox(height: 24),



            // ---- 3. GestureDetector + Container  --------------------------------------------------------------------------

            _sectionHeader(
              '3. GestureDetector + Container',
              '— Botón icono compacto',
            ),
            _codeNote(
             'GestureDetector con Container simple. Fondo y borde indican estado activo/inactivo.\n'
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Captura foto
                _IconCompactButton(                       // = GestureDetector + Container (Construido en el widget _IconCompactButton)
                  icon: Icons.camera_alt,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {},     // onTap no hace nada, pero el botón está habilitado
                ),
                const SizedBox(width: 10),
                // Grabar (toggle)
                _IconCompactButton(
                  icon: _isRecording
                      ? Icons.stop_circle
                      : Icons.fiber_manual_record,
                  active: _isRecording,
                  activeColor: AppColors.danger,
                  onTap: () => setState(() => _isRecording = !_isRecording),  // onTap alterna el estado de grabación
                ),
                const SizedBox(width: 10),
                // Switch cámara
                _IconCompactButton(
                  icon: Icons.cameraswitch,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {}, // onTap no hace nada, pero el botón está habilitado
                ),
                const SizedBox(width: 10),
                // Swap mapa/cámara
                _IconCompactButton(
                  icon: Icons.map,
                  active: false,
                  activeColor: AppColors.primary,
                  onTap: () {}, // onTap no hace nada, pero el botón está habilitado
                ),
              ],
            ),


            const SizedBox(height: 24),



            // ---- 4. Presión continua -----------------------------------------------------------------------------------------------
            _sectionHeader(
              '4. GestureDetector (onLongPress + onTapDown)',
              '— Presión continua',
            ),
            _codeNote(
              'onLongPressStart/End + onTapDown/Up permiten detectar presión continua.\n'
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AltButton(                                                     // = GestureDetector (Construido en el widget _AltButton)
                  up: true,
                  pressed: _altUpPressed,
                  onPressStart: () => setState(() => _altUpPressed = true),   // onLongPressStart y onTapDown activan el estado de presión
                  onPressEnd: () => setState(() => _altUpPressed = false),    // onLongPressEnd y onTapUp desactivan el estado de presión
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



            // ---- 5. Slider (zoom) -----------------------------------------------------------------------------------------------
            _sectionHeader('5. Slider', '— Control de zoom de cámara'),
            _codeNote(
              'Rango 1.0 - 5.0, 8 divisiones.\n',
            ),
            const SizedBox(height: 12),
            Container(                                                                    // Slider con fondo oscuro y borde redondeado
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.zoom_out,                                                       // Icono de zoom out
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  Expanded( 
                    child: SliderTheme(                                               // SliderTheme para personalizar el estilo del Slider
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
                      child: Slider(                                                  // Slider  
                        value: _zoom,
                        min: 1.0, // Rango de zoom de 1.0 a 5.0
                        max: 5.0,
                        divisions: 8, // 8 divisiones para pasos de 0.5
                        // onChanged actualiza el estado con el nuevo valor
                        onChanged: (v) => setState(() => _zoom = v),
                      ),
                    ),
                  ),
                  const Icon(                                                          // Icono de zoom in
                    Icons.zoom_in,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(                                                                 // Etiqueta de zoom actual con un decimal
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



            // ---- 6. DropdownButton -----------------------------------------------------------------------------------------------
            _sectionHeader(
              '6. DropdownButton',
              '— Selector de modo de detección YOLO',
            ),
            _codeNote(
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
              child: DropdownButtonHideUnderline(                         // Oculta la línea inferior del DropdownButton
                child: DropdownButton<String>(                            // DropdownButton para seleccionar el modo de detección
                  value: _detectionMode,  
                  isDense: true,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                  icon: const Icon(                                       // Icono de flecha hacia abajo
                    Icons.arrow_drop_down,
                    color: AppColors.textSecondary,
                    size: 16,
                  ),
                  items: const [                      // Primer ítem: Todos
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
                    DropdownMenuItem(                   // Segundo ítem: Personas
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
                    DropdownMenuItem(                         // Tercer ítem: Ninguno
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
                    if (v != null) setState(() => _detectionMode = v);    // Actualiza el estado con el nuevo valor seleccionado
                  },
                ),
              ),
            ),


            const SizedBox(height: 24),



            // ---- 7. ModeChip / ConnectionChip -------------------------------------------------------------------------------------------------------
            _sectionHeader(
              '7. ModeChip / ConnectionChip',
              '— Selector exclusivo tipo chip',
            ),
            _codeNote(
              'AnimatedContainer con duration 200ms. Seleccionado: borde 2px del color del modo + texto bold.\n'
              'No seleccionado: borde disabled 1px + texto textSecondary.',
            ),
            const SizedBox(height: 10),

            const Text(                                       // Etiqueta de sección para modo de control
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
                _ModeChip(                                                // = AnimatedContainer (Construido en el widget _ModeChip) 
                                                                                  // Primer chip: Classic
                  label: 'Classic',
                  icon: Icons.sports_esports,
                  color: AppColors.primary,
                  selected: _controlMode == 'Classic',
                  onTap: () => setState(() => _controlMode = 'Classic'),
                ),
                _ModeChip(                                                         // Segundo chip: Voice
                  label: 'Voice', 
                  icon: Icons.mic,
                  color: Colors.teal,
                  selected: _controlMode == 'Voice',
                  onTap: () => setState(() => _controlMode = 'Voice'),
                ),
                _ModeChip(                                                         // Tercer chip: IMU
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
                  label: 'ArduPilot',                                             // Primer chip: ArduPilot
                  icon: Icons.developer_board,
                  color: AppColors.primary,
                  selected: _connMode == 'ArduPilot',
                  onTap: () => setState(() => _connMode = 'ArduPilot'),
                ),
                _ModeChip(                                                          // Segundo chip: PX4
                  label: 'SITL',
                  icon: Icons.computer,
                  color: Colors.orange,
                  selected: _connMode == 'SITL',
                  onTap: () => setState(() => _connMode = 'SITL'),
                ),
                _ModeChip(                                                           // Tercer chip: Tello
                  label: 'Tello',
                  icon: Icons.flight,
                  color: Colors.lightBlue,
                  selected: _connMode == 'Tello',
                  onTap: () => setState(() => _connMode = 'Tello'),
                ),
              ],
            ),


            const SizedBox(height: 24),



            // ---- 8. ModalBottomSheet + DraggableScrollableSheet -------------------------------------------------------------------------------
            _sectionHeader(
              '8. ModalBottomSheet + DraggableScrollableSheet',
              '— Hoja de ayuda arrastrable',
            ),
            _codeNote(
              'Arrastrable con showModalBottomSheet + DraggableScrollableSheet.\n'
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(                         // ElevatedButton.icon para mostrar la hoja de ayuda
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
                onPressed: () => _showHelpSheet(context),                           // LLama al método _showHelpSheet para mostrar la hoja de ayuda
              ),
            ),


            const SizedBox(height: 24),



            // ---- 9. AlertDialog ------------------------------------------------------------------------------------------------------------
            _sectionHeader('9. AlertDialog', '— Diálogo de confirmación'),
            _codeNote(
              'Boton ElevatedButton.icon que muestra un AlertDialog con acciones de confirmación.\n'
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(                             // ElevatedButton.icon para mostrar el diálogo de alerta
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
                onPressed: () => _showAlertDialog(context),                   // LLama al método _showAlertDialog para mostrar el diálogo de alerta
              ),
            ),


            const SizedBox(height: 24),



            // ---- 10. ReorderableListView ----------------------------------------------------------------------------------------------
            _sectionHeader(
              '10. ReorderableListView',
              '— Lista reordenable con drag handle',
            ),
            _codeNote(
              'Lista reordenable con drag handle manual y botón para borrar.\n'
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: _ReorderableDemo(items: _reorderItems),        // = ReorderableListView.builder (Construido en el widget _ReorderableDemo)
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }



  // ---------- Métodos para widgets 8 y 9 ----------

  void _showHelpSheet(BuildContext context) {                 // Muestra la hoja de ayuda con showModalBottomSheet + DraggableScrollableSheet
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,                   
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(                        // Builder de DraggableScrollableSheet para permitir arrastrar la hoja
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(        // SingleChildScrollView para permitir desplazamiento dentro de la hoja
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
                  Icon(Icons.flight, color: AppColors.primary, size: 20),       // Título de la hoja de ayuda 
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
              const _HelpSection(                               // Sección de ayuda: Classic Joystick. (Widget auxiliar explicado más abajo)
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
                    'Camera on:  capture photo ·  record video ·  switch camera',
                  ),
                  _HelpItem(
                    Icons.zoom_in,
                    'Zoom bar (x1 - x5) — available in camera view only',
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
              _HelpSection(                                                                     // Sección de ayuda: IMU 
                icon: Icons.sensors,
                title: 'IMU',
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
                    'Dead zone ±5-15° (fwd) / ±10° (lateral) ignored',
                  ),
                  _HelpItem(Icons.info_outline, 'Not available for Tello'),
                ],
              ),
              const SizedBox(height: 16),
              _HelpSection(                                                               // Sección de ayuda: Voice Control
                icon: Icons.mic,
                title: 'Voice Control (es-ES)',
                color: Colors.teal,
                items: const [
                  _HelpItem(
                    Icons.touch_app,
                    'First tap mic — grants microphone permission in the browser',
                  ),
                  _HelpItem(Icons.mic, 'Hold mic - speak - release - executes'),
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
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(                                          // ElevatedButton para cerrar la hoja de ayuda
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

  void _showAlertDialog(BuildContext context) {                   // Muestra un AlertDialog de confirmación con showDialog
    showDialog(
      context: context,
      builder: (_) => AlertDialog(            // AlertDialog con título, contenido y acciones
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
            onPressed: () => Navigator.pop(context),                // Al presionar "Cancel", se cierra el diálogo sin realizar ninguna acción 
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),      //Al pulsar se cierra el diálogo y se ejecuta la acción de borrado (en este caso, solo un print)
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


// WIDGETS AUXILIARES REUTILIZABLES

  // Cabecera de sección
  Widget _sectionHeader(String title, String subtitle) {        // Cabecera de sección con título y subtítulo (widget auxiliar)
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
  Widget _codeNote(String text) {                               // Nota de código / descripción técnica (widget auxiliar)
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


// ---- Widget 2: HudButton (GestureDetector + AnimatedContainer) ----
class _HudButton extends StatelessWidget {      
  // Valores requeridos para el botón: icono, etiqueta, color, estado habilitado, estado activo y callback onTap                                        
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final bool active;
  final VoidCallback onTap;

  const _HudButton({
    // Constructor con parámetros requeridos
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
      onTap: enabled ? onTap : null,  // Si el botón está habilitado, se ejecuta el callback onTap; si no, no hace nada
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
  // variables: icono, estado activo, color activo y callback onTap
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

// ---- Widget 4: Botón de presión continua ----
class _AltButton extends StatelessWidget {
  // variables: dirección (up/down), estado de presión, callbacks onPressStart y onPressEnd
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
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, // Icono de flecha hacia arriba o hacia abajo según la dirección
          color: pressed ? borderColor : AppColors.disabled,
          size: 28,
        ),
      ),
    );
  }
}

// ---- Widget 7: ModeChip  ----
class _ModeChip extends StatelessWidget {
  // variables: etiqueta, icono, color, estado seleccionado y callback onTap
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



// ---- _HelpSection ---- 
class _HelpSection extends StatelessWidget {
  // variables: icono, título, color y lista de items de ayuda
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
        crossAxisAlignment: CrossAxisAlignment.start, // Alinea los elementos hijos al inicio del eje horizontal
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
          ...items, // Despliega la lista de items de ayuda (cada item es un widget _HelpItem)
        ],
      ),
    );
  }
}

class _HelpItem extends StatelessWidget { // item de ayuda individual con icono y texto
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

// ---- Waypoints reorderables  ----
class _ReorderableDemo extends StatefulWidget {
  // variables: lista de items
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
      buildDefaultDragHandles: false,   // Desactiva los drag handles por defecto para usar ReorderableDragStartListener
      onReorder: (oldIndex, newIndex) {
        setState(() {     // Actualiza la lista de items al reordenar
          if (newIndex > oldIndex) newIndex--;
          final item = _items.removeAt(oldIndex);
          _items.insert(newIndex, item);
        });
      },  
      itemBuilder: (ctx, i) => Container(     // Cada item de la lista es un Container con estilo y contenido
        key: ValueKey(_items[i]), // Clave única para cada item basada en su valor
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener( // Empieza el listener de arrastre para reordenar el item
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
            Container(      // Círculo con número de waypoint
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
            Expanded(             // Texto del waypoint
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
              onTap: () => setState(() => _items.removeAt(i)),  // Al presionar el icono de borrar, se elimina el item de la lista
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
