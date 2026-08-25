import 'dart:math';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/telemetry_widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/js_bridges.dart';
import '../core/drone_video_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FlightScreen — pilotaje clásico (modo Classic con ArduPilot o SITL).
//
// Tres franjas: banner de estado arriba, viewport en medio y barra de botones
// abajo. El viewport alterna entre mapa y vídeo WebRTC en el mismo hueco, y los
// dos joysticks flotan encima.
//
// Los joysticks NO van por MQTT: sus valores salen por el DataChannel de WebRTC
// (ver DronProvider.updateJoystick), porque hacen falta decenas de envíos por
// segundo. Los botones de abajo sí son comandos MQTT.
// ─────────────────────────────────────────────────────────────────────────────

class FlightScreen extends StatefulWidget {
  const FlightScreen({super.key});

  @override
  State<FlightScreen> createState() => _FlightScreenState();
}

class _FlightScreenState extends State<FlightScreen> {
  // Solo para el efecto visual del joystick pulsado (borde y halo)
  bool _leftActive = false;
  bool _rightActive = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final bool isPortrait = screenH > screenW;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            StatusBanner(provider: provider),
            Expanded(
              child: isPortrait
                  ? _buildPortraitBody(context, provider, screenW, screenH)
                  : _buildLandscapeBody(context, provider, screenW, screenH),
            ),
            _ActionBar(provider: provider),
          ],
        ),
      ),
    );
  }

  // Horizontal: paneles de instrumentos a los lados y el viewport en el centro.
  // Es la disposición pensada para pilotar (el móvil se sujeta apaisado).
  Widget _buildLandscapeBody(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    final double joystickSize = screenH * 0.32;

    return Row(
      children: [
        // --- Instrumentos izquierda ---
        _LeftInstrumentPanel(
          provider: provider,
          width: screenW * 0.13,
        ),

        // --- Viewport central ---
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Stack(
              children: [
                _MapVideoViewport(provider: provider),
                _MapOverlays(provider: provider),
                // Joystick izquierdo — subir/bajar y girar.
                // El 0.35 recorta el recorrido a un tercio: a fondo de escala el
                // giro y la subida son demasiado bruscos para pilotar con el dedo.
                // La y se invierte porque en pantalla crece hacia abajo y en vuelo
                // "arriba" tiene que ser subir.
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _JoystickPad(
                    size: joystickSize,
                    label: 'THROTTLE / YAW',
                    active: _leftActive,
                    enabled: provider.isFlying,
                    onUpdate: (x, y) {
                      setState(() => _leftActive = true);
                      context.read<DronProvider>().updateJoystick(lx: x * 0.35, ly: -y * 0.35);
                    },
                    onEnd: () {
                      setState(() => _leftActive = false);
                      context.read<DronProvider>().updateJoystick(lx: 0.0, ly: 0.0);
                    },
                  ),
                ),
                // Joystick derecho — avanzar/retroceder y desplazarse de lado.
                // Aquí no se recorta: es el eje que más se usa para desplazarse.
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _JoystickPad(
                    size: joystickSize,
                    label: 'PITCH / ROLL',
                    active: _rightActive,
                    enabled: provider.isFlying,
                    onUpdate: (x, y) {
                      setState(() => _rightActive = true);
                      context.read<DronProvider>().updateJoystick(rx: x, ry: y);
                    },
                    onEnd: () {
                      setState(() => _rightActive = false);
                      context.read<DronProvider>().updateJoystick(rx: 0.0, ry: 0.0);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        // --- Instrumentos derecha ---
        _RightInstrumentPanel(
          provider: provider,
          width: screenW * 0.13,
        ),
      ],
    );
  }

  // Vertical: no caben paneles laterales, así que la telemetría pasa a una fila
  // compacta arriba y el viewport ocupa todo lo demás.
  Widget _buildPortraitBody(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    final double joystickSize = screenH * 0.17;

    return Column(
      children: [
        // Telemetría horizontal compacta
        CompactTelemetryRow(provider: provider),

        // Viewport
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Stack(
              children: [
                _MapVideoViewport(provider: provider),
                _MapOverlays(provider: provider),
                // Joystick izquierdo
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: _JoystickPad(
                    size: joystickSize,
                    label: 'THR/YAW',
                    active: _leftActive,
                    enabled: provider.isFlying,
                    onUpdate: (x, y) {
                      setState(() => _leftActive = true);
                      context.read<DronProvider>().updateJoystick(lx: x * 0.35, ly: -y * 0.35);
                    },
                    onEnd: () {
                      setState(() => _leftActive = false);
                      context.read<DronProvider>().updateJoystick(lx: 0.0, ly: 0.0);
                    },
                  ),
                ),
                // Joystick derecho
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _JoystickPad(
                    size: joystickSize,
                    label: 'PCH/ROLL',
                    active: _rightActive,
                    enabled: provider.isFlying,
                    onUpdate: (x, y) {
                      setState(() => _rightActive = true);
                      context.read<DronProvider>().updateJoystick(rx: x, ry: y);
                    },
                    onEnd: () {
                      setState(() => _rightActive = false);
                      context.read<DronProvider>().updateJoystick(rx: 0.0, ry: 0.0);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Left Instrument Panel (landscape) ────────────────────────────────────────
// Datos de posición y movimiento: altitud, velocidad y coordenadas. Las
// coordenadas van con 6 decimales para poder compararlas con Mission Planner.

class _LeftInstrumentPanel extends StatelessWidget {
  final DronProvider provider;
  final double width;
  const _LeftInstrumentPanel({required this.provider, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _InstrumentTile(
            label: 'ALT',
            value: provider.currentAlt.toStringAsFixed(2),
            unit: 'm',
            icon: Icons.height,
          ),
          const SizedBox(height: 16),
          _InstrumentTile(
            label: 'GS',
            value: provider.currentSpeed.toStringAsFixed(2),
            unit: 'm/s',
            icon: Icons.speed,
          ),
          const SizedBox(height: 16),
          _InstrumentTile(
            label: 'LAT',
            value: '${provider.currentLat.toStringAsFixed(6)}°',
            unit: '',
            icon: Icons.location_on,
            small: true,
          ),
          const SizedBox(height: 8),
          _InstrumentTile(
            label: 'LON',
            value: '${provider.currentLon.toStringAsFixed(6)}°',
            unit: '',
            icon: Icons.location_searching,
            small: true,
          ),
        ],
      ),
    );
  }
}

// ── Right Instrument Panel (landscape) ───────────────────────────────────────
// Datos de orientación y estado: brújula, rumbo y estado del vehículo.

class _RightInstrumentPanel extends StatelessWidget {
  final DronProvider provider;
  final double width;
  const _RightInstrumentPanel({required this.provider, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CompassRose(heading: provider.currentHeading),
          const SizedBox(height: 16),
          _InstrumentTile(
            label: 'HDG',
            value: '${provider.currentHeading.toInt()}',
            unit: '°',
            icon: Icons.explore,
          ),
          const SizedBox(height: 14),
          _InstrumentTile(
            label: 'STATE',
            value: provider.currentState,
            unit: '',
            icon: Icons.info_outline,
            small: true,
          ),
        ],
      ),
    );
  }
}

// ── Instrument Tile ───────────────────────────────────────────────────────────
// Celda genérica etiqueta + valor + unidad. Usa cifras de ancho fijo
// (tabularFigures) para que el número no baile al cambiar de dígito.

class _InstrumentTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final bool small;

  const _InstrumentTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary, size: 10),
            const SizedBox(width: 3),
            Text(label, style: TextStyles.instrumentLabel),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: small
              ? const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                )
              : TextStyles.instrument,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        if (unit.isNotEmpty)
          Text(
            unit,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 9,
            ),
          ),
      ],
    );
  }
}

// ── Compass Rose ──────────────────────────────────────────────────────────────
// Brújula: lo que gira es la aguja (según el rumbo del dron), no la rosa. La N
// se queda fija arriba, como en una brújula de verdad.

class _CompassRose extends StatelessWidget {
  final double heading;
  const _CompassRose({required this.heading});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Anillo exterior
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: 1.5),
              color: AppColors.background,
            ),
          ),
          // Norte giratorio
          Transform.rotate(
            angle: heading * pi / 180,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 2,
                  height: 12,
                  color: AppColors.danger,
                ),
                Container(
                  width: 2,
                  height: 12,
                  color: AppColors.disabled,
                ),
              ],
            ),
          ),
          // Centro
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary,
            ),
          ),
          // Letra N fija arriba
          const Positioned(
            top: 3,
            child: Text(
              'N',
              style: TextStyle(
                color: AppColors.danger,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Joystick Pad ──────────────────────────────────────────────────────────────
// Envoltorio del joystick de la librería. Si el dron no vuela, en lugar del
// stick muestra un candado: es la barrera visual que impide mover el dron antes
// de despegar (la comprobación real está en el provider).

class _JoystickPad extends StatelessWidget {
  final double size;
  final String label;
  final bool active;
  final bool enabled;
  final void Function(double x, double y) onUpdate;
  final VoidCallback onEnd;

  const _JoystickPad({
    required this.size,
    required this.label,
    required this.active,
    required this.enabled,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface.withValues(alpha: 0.75),
            border: Border.all(
              color: active
                  ? AppColors.primary
                  : enabled
                      ? AppColors.border
                      : AppColors.disabled.withValues(alpha: 0.4),
              width: active ? 2.5 : 1.5,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 18,
                      spreadRadius: 2,
                    )
                  ]
                : null,
          ),
          child: enabled
              ? Joystick(
                  mode: JoystickMode.all,
                  listener: (details) => onUpdate(details.x, details.y),
                  onStickDragEnd: onEnd,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        color: AppColors.disabled,
                        size: size * 0.18,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'TAKEOFF\nTO ENABLE',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.disabled,
                          fontSize: size * 0.07,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 8,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

// ── Map / Video Viewport ──────────────────────────────────────────────────────
// El mismo hueco muestra el mapa o el vídeo de la cámara según isVideoActive.
// El borde se enciende en azul mientras el dron vuela.

class _MapVideoViewport extends StatelessWidget {
  final DronProvider provider;
  const _MapVideoViewport({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: provider.isFlying ? AppColors.primary : AppColors.border,
            width: provider.isFlying ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: provider.isVideoActive
              ? (provider.remoteStream != null
                  ? SizedBox.expand(
                      child: DroneVideoView(stream: provider.remoteStream!),
                    )
                  : const Center(
                      child: Text(
                        'Waiting Stream...',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ))
              : FlutterMap(
                  // Se centra donde está el dron y, si aún no hay telemetría,
                  // en el campus de la EETAC. Ojo: "initial" significa que solo
                  // se aplica al construir el mapa; la cámara NO persigue al dron.
                  options: MapOptions(
                    initialCenter: LatLng(
                      provider.currentLat != 0.0 ? provider.currentLat : 41.2765,
                      provider.currentLon != 0.0 ? provider.currentLon : 1.9888,
                    ),
                    initialZoom: 17,
                  ),
                  // Capas apiladas de abajo arriba: satélite, traza, vector de
                  // velocidad, posición del usuario, sombra y dron.
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.example.app',
                    ),
                    if (provider.droneTrail.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: provider.droneTrail,
                            color: const Color.fromARGB(255, 121, 40, 198),
                            strokeWidth: 2.0,
                          ),
                        ],
                      ),
                    if (provider.isFlying)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [
                              LatLng(provider.currentLat, provider.currentLon),
                              _calcVelocityEndPoint(
                                provider.currentLat,
                                provider.currentLon,
                                provider.currentVx,
                                provider.currentVy,
                              ),
                            ],
                            color: const Color.fromARGB(255, 0, 255, 132),
                            strokeWidth: 2.0,
                          ),
                        ],
                      ),
                    if (provider.userPosition != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: provider.userPosition!,
                            width: 44,
                            height: 44,
                            child: const Icon(
                              FontAwesomeIcons.mobileScreen,
                              color: Colors.blue,
                              size: 28,
                            ),
                          ),
                        ],
                      ),
                    // Sombra bajo el dron, solo en vuelo: da sensación de altura.
                    // Los ValueListenableBuilder de aquí abajo escuchan la posición
                    // INTERPOLADA a 60 fps del provider, no la telemetría cruda.
                    // Así el icono se desliza en vez de saltar entre paquetes, y
                    // además solo se repinta el marcador, no la pantalla entera.
                    if (provider.isFlying)
                      ValueListenableBuilder<LatLng>(
                        valueListenable: provider.droneRenderPos,
                        builder: (_, renderPos, _) => CircleLayer(
                          circles: [
                            CircleMarker(
                              point: renderPos,
                              radius: 10,
                              color: const Color.fromARGB(181, 171, 171, 171),
                              borderColor: Colors.grey,
                              borderStrokeWidth: 1,
                              useRadiusInMeter: false,
                            ),
                          ],
                        ),
                      ),
                    ValueListenableBuilder<LatLng>(
                      valueListenable: provider.droneRenderPos,
                      builder: (_, renderPos, _) => ValueListenableBuilder<double>(
                        valueListenable: provider.droneRenderHeading,
                        builder: (_, renderHeading, _) => MarkerLayer(
                          markers: [
                            Marker(
                              point: renderPos,
                              width: 32,
                              height: 48,
                              child: Transform.rotate(
                                angle: renderHeading * pi / 180,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    // RepaintBoundary aísla el icono en su propia
                                    // capa de dibujo: al rotar 60 veces por segundo,
                                    // evita repintar todo lo que hay debajo.
                                    RepaintBoundary(
                                      child: Image.asset(
                                        'assets/images/drone_icon.png',
                                        width: 24,
                                        height: 24,
                                      ),
                                    ),
                                    const Positioned(
                                      top: -14,
                                      child: Icon(
                                        Icons.arrow_upward,
                                        color: AppColors.warning,
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
      ),
    );
  }
}

// ── Map Overlays (badges, controls sobre el mapa/vídeo) ───────────────────────

class _MapOverlays extends StatelessWidget {
  final DronProvider provider;
  const _MapOverlays({required this.provider});

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final bool isPortrait = screenH > screenW;

    return Stack(
      children: [
        // Badge GPS (solo en mapa). El color avisa de la calidad de la señal:
        // verde hasta 5 m de error, naranja hasta 20 y rojo por encima.
        if (provider.userPosition != null && !provider.isVideoActive)
          Positioned(
            top: 10,
            left: 10,
            child: _MapBadge(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.gps_fixed,
                    size: 11,
                    color: provider.userAccuracy <= 5
                        ? Colors.green
                        : provider.userAccuracy <= 20
                            ? Colors.orange
                            : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${provider.userAccuracy.toStringAsFixed(1)} m',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: provider.userAccuracy <= 5
                          ? Colors.green
                          : provider.userAccuracy <= 20
                              ? Colors.orange
                              : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Fila top-right: swap + controles de cámara si está activo el vídeo.
        // Foto, grabar y cambiar de cámara solo tienen sentido viendo el vídeo;
        // el botón de swap mapa/vídeo está siempre.
        Positioned(
          top: 8,
          right: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (provider.isVideoActive) ...[
                _IconBadgeButton(
                  icon: Icons.camera_alt,
                  onTap: () => context.read<DronProvider>().capturePhoto(),
                ),
                const SizedBox(width: 6),
                _IconBadgeButton(
                  icon: provider.isRecording
                      ? Icons.stop_circle
                      : Icons.fiber_manual_record,
                  active: provider.isRecording,
                  activeColor: AppColors.danger,
                  onTap: () {
                    if (provider.isRecording) {
                      context.read<DronProvider>().stopRecording();
                    } else {
                      context.read<DronProvider>().startRecording();
                    }
                  },
                ),
                const SizedBox(width: 6),
                _IconBadgeButton(
                  icon: Icons.cameraswitch,
                  active: provider.cameraIndex == 1,
                  activeColor: AppColors.primary,
                  onTap: () => context.read<DronProvider>().switchCamera(),
                ),
                const SizedBox(width: 6),
              ],
              _IconBadgeButton(
                icon: provider.isVideoActive ? Icons.map : Icons.videocam,
                onTap: () => context.read<DronProvider>().toggleVideo(),
              ),
            ],
          ),
        ),

        // Dropdown YOLO (solo en vídeo). Lo que se elige aquí viaja por MQTT a la
        // estación de tierra: es ella la que decide qué dibujar sobre los frames.
        if (provider.isVideoActive)
          Positioned(
            top: 8,
            left: 8,
            child: _DetectionDropdown(
              current: provider.detectionMode,
              onChanged: (mode) =>
                  context.read<DronProvider>().setDetectionMode(mode),
            ),
          ),

        // Badge REC
        if (provider.isRecording && provider.isVideoActive)
          const Positioned(
            bottom: 8,
            left: 8,
            child: _RecBadge(),
          ),

        // Barra de zoom: vertical en retrato y horizontal en apaisado, para no
        // tapar el vídeo ni quedar debajo de los joysticks.
        if (provider.isVideoActive)
          if (isPortrait)
            Positioned(
              left: 6,
              top: 0,
              bottom: 0,
              child: Center(child: _ZoomBarVertical(provider: provider)),
            )
          else
            Positioned(
              left: 60,
              right: 60,
              bottom: 8,
              child: _ZoomBarHorizontal(provider: provider),
            ),
      ],
    );
  }
}

// ── Action Bar ────────────────────────────────────────────────────────────────
// Los cinco comandos discretos, los que sí van por MQTT. Están agrupados por
// fases del vuelo y separados por líneas: preparación (ARM, TAKEOFF), vuelta
// (LAND, RTL) y, aparte, DISCONNECT.
// Cada botón repite la condición de estado que ya comprueba el provider: aquí
// es para que el usuario vea qué puede hacer, no para proteger el dron.

class _ActionBar extends StatelessWidget {
  final DronProvider provider;
  const _ActionBar({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          // Grupo preparación
          Expanded(
            child: _ActionButton(
              icon: Icons.power_settings_new,
              label: 'ARM',
              enabled: !provider.isLoading &&
                  provider.isConnected &&
                  !provider.isArmed &&
                  !provider.isFlying,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().armDron(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _ActionButton(
              icon: Icons.flight_takeoff,
              label: 'TAKEOFF',
              enabled: !provider.isLoading &&
                  provider.isConnected &&
                  provider.isArmed &&
                  !provider.isFlying,
              color: AppColors.primary,
              onTap: () => context.read<DronProvider>().takeOff(),
            ),
          ),

          // Separador visual
          Container(
            width: 1,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: AppColors.border,
          ),

          // Grupo retorno/aterrizaje
          Expanded(
            child: _ActionButton(
              icon: Icons.flight_land,
              label: 'LAND',
              enabled: !provider.isLoading &&
                  provider.isConnected &&
                  provider.isFlying,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().land(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _ActionButton(
              icon: Icons.home,
              label: 'RTL',
              enabled: !provider.isLoading &&
                  provider.isConnected &&
                  provider.isFlying,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().rtl(),
            ),
          ),

          // Separador visual
          Container(
            width: 1,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: AppColors.border,
          ),

          // DISCONNECT aislado y bloqueado mientras el dron esté armado o
          // volando: desconectar en el aire dejaría al dron sin nadie al mando.
          // Primero aterrizar, luego desarmar, y solo entonces desconectar.
          Expanded(
            child: _ActionButton(
              icon: Icons.link_off,
              label: 'DISCONNECT',
              enabled: !provider.isLoading &&
                  provider.isConnected &&
                  !provider.isArmed &&
                  !provider.isFlying,
              color: AppColors.danger,
              outlined: true,
              // Al salir: deshacer la pantalla completa, desconectar y volver
              // a la pantalla de configuración.
              onTap: () {
                exitFullscreenEZ();
                context.read<DronProvider>().disconnectDron();
                Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Botón de la barra inferior. Con outlined:true sale solo con borde (se reserva
// para DISCONNECT, para que no se confunda con los botones de vuelo).
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color color;
  final bool outlined;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.color,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = outlined
        ? (enabled ? color : AppColors.textSecondary)
        : AppColors.textPrimary;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: outlined
              ? (enabled ? color.withValues(alpha: 0.12) : Colors.transparent)
              : (enabled ? color : AppColors.disabled),
          borderRadius: BorderRadius.circular(8),
          border: outlined
              ? Border.all(
                  color: enabled ? color : AppColors.disabled,
                  width: 1.5,
                )
              : enabled
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 1,
                    )
                  : null,
          boxShadow: enabled && !outlined
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: textColor),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helpers de overlays ───────────────────────────────────────────────────────

class _MapBadge extends StatelessWidget {
  final Widget child;
  const _MapBadge({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class _IconBadgeButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;

  const _IconBadgeButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = active && activeColor != null
        ? activeColor!
        : AppColors.surface.withValues(alpha: 0.92);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active && activeColor != null
                ? activeColor!
                : AppColors.border,
          ),
        ),
        child: Icon(icon, color: AppColors.textPrimary, size: 16),
      ),
    );
  }
}

class _RecBadge extends StatelessWidget {
  const _RecBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: Colors.white, size: 8),
          SizedBox(width: 4),
          Text(
            'REC',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomBarVertical extends StatelessWidget {
  final DronProvider provider;
  const _ZoomBarVertical({required this.provider});

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      width: 36,
      height: screenH * 0.35,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${provider.zoomLevel.toStringAsFixed(1)}×',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: _ZoomSlider(provider: provider),
            ),
          ),
          const SizedBox(height: 2),
          const Icon(Icons.zoom_in, color: AppColors.textSecondary, size: 12),
        ],
      ),
    );
  }
}

class _ZoomBarHorizontal extends StatelessWidget {
  final DronProvider provider;
  const _ZoomBarHorizontal({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.zoom_out, color: AppColors.textSecondary, size: 12),
          const SizedBox(width: 4),
          Expanded(child: _ZoomSlider(provider: provider)),
          const SizedBox(width: 4),
          const Icon(Icons.zoom_in, color: AppColors.textSecondary, size: 12),
          const SizedBox(width: 6),
          Text(
            '${provider.zoomLevel.toStringAsFixed(1)}x',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomSlider extends StatelessWidget {
  final DronProvider provider;
  const _ZoomSlider({required this.provider});

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.disabled,
        thumbColor: AppColors.primary,
        overlayColor: AppColors.primary,
      ),
      child: Slider(
        value: provider.zoomLevel,
        min: 1.0,
        max: 5.0,
        divisions: 8,
        onChanged: (v) => context.read<DronProvider>().setZoom(v),
      ),
    );
  }
}

// ── Detection Dropdown ────────────────────────────────────────────────────────

class _DetectionDropdown extends StatelessWidget {
  final DetectionMode current;
  final ValueChanged<DetectionMode> onChanged;

  const _DetectionDropdown({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<DetectionMode>(
          value: current,
          isDense: true,
          dropdownColor: AppColors.surface,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
          icon: const Icon(
            Icons.arrow_drop_down,
            color: AppColors.textSecondary,
            size: 16,
          ),
          items: const [
            DropdownMenuItem(
              value: DetectionMode.all,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.select_all, color: AppColors.primary, size: 13),
                  SizedBox(width: 5),
                  Text('Todo'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: DetectionMode.person,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person, color: AppColors.primary, size: 13),
                  SizedBox(width: 5),
                  Text('Personas'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: DetectionMode.none,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off, color: AppColors.disabled, size: 13),
                  SizedBox(width: 5),
                  Text('Ninguno'),
                ],
              ),
            ),
          ],
          onChanged: (mode) {
            if (mode != null) onChanged(mode);
          },
        ),
      ),
    );
  }
}

// ── Velocity endpoint ─────────────────────────────────────────────────────────
// Calcula dónde acaba la flecha verde de velocidad: se parte de la posición del
// dron y se avanza en la dirección en que se mueve.
// Para pasar de metros a grados se usa que un grado de latitud son ~111.320 m;
// en longitud hay que corregir por el coseno de la latitud, porque los
// meridianos se juntan al acercarse a los polos.

LatLng _calcVelocityEndPoint(double lat, double lon, double vx, double vy) {
  // Con el dron casi quieto no se dibuja nada, para que no tiemble una flecha
  // apuntando al ruido de la medida.
  final speed = sqrt(vx * vx + vy * vy);
  if (speed < 0.5) return LatLng(lat, lon);
  const scale = 6.0;
  final dlat = (vx * scale) / 111320;
  final dlon = (vy * scale) / (111320 * cos(lat * pi / 180));
  // El /50 final acorta la flecha para que quepa en el zoom del mapa: es un
  // indicador visual de dirección, no una medida a escala.
  return LatLng((lat + dlat/50), (lon + dlon/50));
}
