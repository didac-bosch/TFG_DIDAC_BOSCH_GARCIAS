import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../provider.dart';
import '../core/styles.dart';
import '../core/js_bridges.dart';
import '../core/telemetry_widgets.dart';

// JS bridge — funciones expuestas desde index.html
@JS()
external void requestMotionPermission();
@JS()
external void stopOrientation();
@JS()
external double getAlpha(); // yaw   (0–360°)
@JS()
external double getBeta(); // pitch (-180–180°)
@JS()
external double getGamma(); // roll  (-90–90°)

// Modos de control IMU:
// normal  - inclinar el dispositivo hacia adelante = avanzar
// volante - sostener el dispositivo como un volante horizontal
enum _ImuMode { normal, volante }

// Lee alpha/beta/gamma del giroscopio a 20 Hz
// y los convierte en comandos de joystick enviados al provider.
class ImuFlightScreen extends StatefulWidget {
  const ImuFlightScreen({super.key});

  @override
  State<ImuFlightScreen> createState() => _ImuFlightScreenState();
}

// Pantalla de vuelo con control por IMU y mapa integrado.
class _ImuFlightScreenState extends State<ImuFlightScreen> {
  bool _imuActive = false;
  _ImuMode _mode = _ImuMode.normal;
  Timer? _timer; // timer periódico a 50 ms (20 Hz)

  double _pitch = 0.0; // beta  — inclinación adelante/atrás
  double _roll = 0.0; // gamma — inclinación lateral
  double _yaw = 0.0; // alpha — rotación sobre eje vertical

  double _lyButton = 0.0;

  final MapController _mapController = MapController();

  // Bloquea la orientación de pantalla según el modo activo:
  // portrait para NORMAL, landscape para VOLANTE.
  void _applyOrientation() {
    if (_mode == _ImuMode.volante) {
      lockOrientationEZ('landscape');
    } else {
      lockOrientationEZ('portrait');
    }
  }

  @override
  void initState() {
    super.initState();
    _applyOrientation(); // portrait al entrar (modo NORMAL por defecto)
  }

  @override
  void dispose() {
    _stopImu();
    unlockOrientationEZ(); // libera la orientación al salir
    _mapController.dispose();
    super.dispose();
  }

  // Arranca el timer de lectura IMU y solicita permiso de movimiento (iOS).
  void _startImu() {
    requestMotionPermission();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      final alpha = getAlpha();
      final beta = getBeta();
      final gamma = getGamma();
      setState(() {
        _yaw = alpha;
        _pitch = beta;
        _roll = gamma;
      });
      // Solo envía comandos si el dron está armado
      if (context.read<DronProvider>().isArmed) {
        _sendJoystick(beta, gamma);
      }
    });
    setState(() => _imuActive = true);
  }

  // Para el timer, llama a stopOrientation en JS y pone los ejes en 0.
  void _stopImu() {
    _timer?.cancel();
    _timer = null;
    _lyButton = 0.0;
    stopOrientation();
    if (mounted) {
      context.read<DronProvider>().updateJoystick(lx: 0, ly: 0, rx: 0, ry: 0);
      setState(() => _imuActive = false);
    }
  }

  // Convierte beta y gamma en ejes rx/ry según el modo activo
  // y los envía al provider (lx/ly siempre 0 — altitud via botones).
  void _sendJoystick(double beta, double gamma) {
    final double ry;
    final double rx;
    if (_mode == _ImuMode.normal) {
      ry = -_normalForward(beta);
      rx = _normalLateral(gamma);
    } else {
      ry = _volanteForward(gamma);
      rx = _volanteLateral(beta);
    }
    // _lyButton se incorpora al paquete en lugar de siempre ser 0
    context.read<DronProvider>().updateJoystick(
      lx: 0,
      ly: _lyButton * 0.35,
      rx: rx,
      ry: ry,
    );
  }

  // Zona muerta ±5°/15°, rampa lineal hasta ±1.0 en 40°
  double _normalForward(double b) {
    if (b > 15) return -min((b - 15) / 40.0, 1.0);
    if (b < -5) return min((-5 - b) / 40.0, 1.0);
    return 0.0;
  }

  // Zona muerta ±10°, rampa lineal hasta ±1.0 en 40°
  double _normalLateral(double g) {
    if (g > 10) return min((g - 10) / 40.0, 1.0);
    if (g < -10) return -min((-10 - g) / 40.0, 1.0);
    return 0.0;
  }

  // Gamma neutro ≈ -50° (dispositivo horizontal boca arriba), rampa 30°
  double _volanteForward(double g) {
    if (g > -40) return -min((g + 40) / 30.0, 1.0);
    if (g < -60) return min((-60 - g) / 30.0, 1.0);
    return 0.0;
  }

  // Inclinación lateral del volante: zona muerta ±15°, rampa 30°
  double _volanteLateral(double b) {
    if (b > 15) return min((b - 15) / 30.0, 1.0);
    if (b < -15) return -min((-15 - b) / 30.0, 1.0);
    return 0.0;
  }

  // Ángulos remapeados para el horizonte artificial según el modo (SOLO visual,
  // no afecta a las rampas ni al control). En volante el dispositivo se sostiene
  // en horizontal: el eje adelante/atrás lo marca gamma (_roll, neutro ≈ -50°) y
  // el lateral lo marca beta (_pitch), así que se intercambian y se compensa el
  // neutro para que el horizonte coincida con cómo se sujeta el móvil.
  double get _adiPitch => _mode == _ImuMode.volante ? _roll + 50.0 : _pitch;
  double get _adiRoll => _mode == _ImuMode.volante ? _pitch : _roll;

  // Recentra el mapa sobre el dron si tiene posición GPS válida.
  void _centerOnDrone(double lat, double lon) {
    if (lat != 0.0 && lon != 0.0) {
      try {
        _mapController.move(LatLng(lat, lon), _mapController.camera.zoom);
      } catch (_) {}
    }
  }

  // Calcula el punto final del vector de velocidad para dibujarlo en el mapa.
  LatLng _calcVelocityEndPoint(double lat, double lon, double vx, double vy) {
    final speed = sqrt(vx * vx + vy * vy);
    if (speed < 0.5) return LatLng(lat, lon);
    const scale = 6.0;
    final dlat = (vx * scale) / 111320;
    final dlon = (vy * scale) / (111320 * cos(lat * pi / 180));
    return LatLng((lat + dlat/50), (lon + dlon/50));
  }

  // Widget botón altitud reutilizable
  Widget _buildAltButton({
    required bool up,
    required bool isFlying,
    required BuildContext ctx,
    double iconSize = 20,
    double padding = 6,
  }) {
    return GestureDetector(
      //Gesture detector
      onLongPressStart: (_) {
        if (!isFlying) return;
        setState(() => _lyButton = up ? 1.0 : -1.0);
      },
      onLongPressEnd: (_) {
        setState(() => _lyButton = 0.0);
      },
      onTapDown: (_) {
        if (!isFlying) return;
        setState(() => _lyButton = up ? 1.0 : -1.0);
      },
      onTapUp: (_) {
        setState(() => _lyButton = 0.0);
      },
      onTapCancel: () {
        setState(() => _lyButton = 0.0);
      },
      child: Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: isFlying
              ? AppColors.surface.withValues(alpha: 0.92)
              : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isFlying
                ? (up ? AppColors.primary : AppColors.warning)
                : AppColors.disabled,
          ),
        ),
        child: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          color: isFlying
              ? (up ? AppColors.primary : AppColors.warning)
              : AppColors.disabled,
          size: iconSize,
        ),
      ),
    );
  }

  Widget _buildBottomButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
    Color color = AppColors.warning,
    bool outlined = false,
  }) {
    final textColor = outlined
        ? (enabled ? color : AppColors.textSecondary)
        : AppColors.textPrimary;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: outlined
              ? (enabled ? color.withValues(alpha: 0.1) : Colors.transparent)
              : (enabled ? color : AppColors.disabled),
          borderRadius: BorderRadius.circular(8),
          border: outlined
              ? Border.all(
                  color: enabled ? color : AppColors.disabled,
                  width: 1.5,
                )
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Flecha de velocidad creciente según magnitud y orientada según dirección de movimiento
  Widget _buildVelocityArrow(double vx, double vy) {
    final speed = sqrt(vx * vx + vy * vy);
    final angle = atan2(vy, vx);
    final bool moving = speed > 0.3;
    const double maxSize = 22.0;
    final double norm = ((speed - 0.3) / 4.7).clamp(0.0, 1.0);
    final double arrowSz = (maxSize * norm).clamp(0.0, maxSize);
    const green = Color.fromARGB(255, 0, 255, 132);

    // El widget se vuelve más opaco y con borde verde al moverse, y más pequeño cuanto más lento va.
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: moving ? 1.0 : 0.5,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: moving ? green : AppColors.disabled),
        ),
        child: SizedBox(
          width: maxSize,
          height: maxSize,
          child: Center(
            child: moving
                ? Transform.rotate(
                    angle: angle,
                    child: Icon(Icons.navigation, color: green, size: arrowSz),
                  )
                : Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.disabled,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // Dos gauges lineales que muestran la zona muerta y la posición actual
  // de los ejes de control según el modo activo (NORMAL / VOLANTE).
  // Solo dibujan a partir de _pitch/_roll/_mode; no leen ni cambian las rampas.
  Widget _buildGaugesColumn() {
    // Configuración de cada gauge según el modo (refleja visualmente las
    // zonas muertas de las funciones de rampa, sin acceder a sus constantes).
    final List<_GaugeConfig> cfgs = _mode == _ImuMode.normal
        ? [
            _GaugeConfig('FWD / BACK', _pitch, -45, 55, -5, 15, Colors.cyan),
            _GaugeConfig(
              'LEFT / RIGHT',
              _roll,
              -50,
              50,
              -10,
              10,
              Colors.lightBlue,
            ),
            _GaugeConfig('YAW', _yaw, 0, 360, 0, 0, Colors.purpleAccent),
          ]
        : [
            _GaugeConfig('FWD / BACK', _roll, -90, -10, -60, -40, Colors.cyan),
            _GaugeConfig(
              'LEFT / RIGHT',
              _pitch,
              -45,
              45,
              -15,
              15,
              Colors.lightBlue,
            ),
            _GaugeConfig('YAW', _yaw, 0, 360, 0, 0, Colors.purpleAccent),
          ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < cfgs.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _DeadZoneGauge(
            label: cfgs[i].label,
            value: cfgs[i].value,
            minDeg: cfgs[i].minDeg,
            maxDeg: cfgs[i].maxDeg,
            deadLow: cfgs[i].deadLow,
            deadHigh: cfgs[i].deadHigh,
            accent: cfgs[i].accent,
            active: _imuActive,
          ),
        ],
      ],
    );
  }

  // Panel IMU
  Widget _buildLandscapeImuPanel() {
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _imuActive ? Colors.deepPurple : AppColors.border,
          width: _imuActive ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Horizonte artificial
          Center(
            child: _AttitudeIndicator(
              pitch: _adiPitch,
              roll: _adiRoll,
              active: _imuActive,
              size: 72,
            ),
          ),
          const SizedBox(height: 10),
          // Gauges de zona muerta (incluye YAW)
          _buildGaugesColumn(),
          const SizedBox(height: 10),
          // Botón START / STOP IMU
          GestureDetector(
            onTap: _imuActive ? _stopImu : _startImu,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: _imuActive ? AppColors.danger : Colors.deepPurple,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _imuActive ? Icons.sensors_off : Icons.sensors,
                    color: Colors.white,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _imuActive ? 'STOP' : 'START',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Toggle NORMAL / VOLANTE — también bloquea orientación
          GestureDetector(
            onTap: () => setState(
              () => _mode = _mode == _ImuMode.normal
                  ? _ImuMode.volante
                  : _ImuMode.normal,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.deepPurple),
              ),
              child: Text(
                _mode == _ImuMode.normal ? 'VERTICAL' : 'WHEEL',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.deepPurple,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Construcción de la pantalla completa con mapa, telemetría y panel IMU.
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final bool isPortrait = screenH > screenW;

    // Posición inicial del mapa: dron si tiene GPS, campus EETAC si no
    final double droneLat = provider.currentLat != 0.0
        ? provider.currentLat
        : 41.2765;
    final double droneLon = provider.currentLon != 0.0
        ? provider.currentLon
        : 1.9888;

    // Seguimiento automático del dron en el mapa tras cada rebuild
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOnDrone(provider.currentLat, provider.currentLon);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // --------- BARRA SUPERIOR: CHIPS DE ESTADO + BATERÍA + MENSAJE ---
            StatusBanner(provider: provider),
            // --------- BARRA DE TELEMETRÍA ----------------------------------
            CompactTelemetryRow(provider: provider),

            // ---------- ZONA CENTRAL ----------------
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: screenH * 0.01,
                  horizontal: screenW * 0.015,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      children: [
                        // -------- MAPA SATELITAL ----------------
                        FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: LatLng(droneLat, droneLon),
                            initialZoom: 17,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName: 'com.example.app',
                            ),
                            // Trail de posiciones anteriores del dron
                            if (provider.droneTrail.length > 1)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: provider.droneTrail,
                                    color: const Color.fromARGB(
                                      255,
                                      121,
                                      40,
                                      198,
                                    ),
                                    strokeWidth: 2.0,
                                  ),
                                ],
                              ),
                            // Vector de velocidad instantánea
                            if (provider.isFlying)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: [
                                      LatLng(
                                        provider.currentLat,
                                        provider.currentLon,
                                      ),
                                      _calcVelocityEndPoint(
                                        provider.currentLat,
                                        provider.currentLon,
                                        provider.currentVx,
                                        provider.currentVy,
                                      ),
                                    ],
                                    color: const Color.fromARGB(
                                      255,
                                      0,
                                      255,
                                      132,
                                    ),
                                    strokeWidth: 2.0,
                                  ),
                                ],
                              ),
                            // Marcador del operador
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
                            // Sombra gris en la posición del dron (cuando está volando)
                            if (provider.isFlying)
                              CircleLayer(
                                circles: [
                                  CircleMarker(
                                    point: LatLng(
                                      provider.currentLat,
                                      provider.currentLon,
                                    ),
                                    radius: 10,
                                    color: const Color.fromARGB(
                                      181,
                                      171,
                                      171,
                                      171,
                                    ),
                                    borderColor: Colors.grey,
                                    borderStrokeWidth: 1,
                                    useRadiusInMeter: false,
                                  ),
                                ],
                              ),
                            // Icono del dron rotado según heading + flecha de dirección
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: LatLng(droneLat, droneLon),
                                  width: 32,
                                  height: 48,
                                  child: Transform.rotate(
                                    angle: provider.currentHeading * pi / 180,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      alignment: Alignment.center,
                                      children: [
                                        RepaintBoundary(
                                          child: Image.asset(
                                            'assets/images/drone_icon.png',
                                            width: 24,
                                            height: 24,
                                          ),
                                        ),
                                        const Positioned(
                                          top: -18,
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
                          ],
                        ),

                        // ----------- Botones altitud ------------
                        Positioned(
                          left: 8,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildAltButton(
                                  up: true,
                                  isFlying: provider.isFlying,
                                  ctx: context,
                                  iconSize: 26,
                                  padding: 8,
                                ),
                                const SizedBox(height: 8),
                                _buildAltButton(
                                  up: false,
                                  isFlying: provider.isFlying,
                                  ctx: context,
                                  iconSize: 26,
                                  padding: 8,
                                ),
                              ],
                            ),
                          ),
                        ),

                        // ----- Flecha velocidad
                        if (provider.isFlying)
                          isPortrait
                              ? Positioned(
                                  right: 8,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(
                                    child: _buildVelocityArrow(
                                      provider.currentVx,
                                      provider.currentVy,
                                    ),
                                  ),
                                )
                              : Positioned(
                                  top: 10,
                                  left: 8,
                                  child: _buildVelocityArrow(
                                    provider.currentVx,
                                    provider.currentVy,
                                  ),
                                ),

                        if (!isPortrait)
                          Positioned(
                            right: 8,
                            top: 8,
                            bottom: 8,
                            child: SingleChildScrollView(
                              child: _buildLandscapeImuPanel(),
                            ),
                          ),

                        // ----------- Panel IMU abajo — solo portrait
                        if (isPortrait)
                          Positioned(
                            bottom: 10,
                            left: 10,
                            right: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surface.withValues(
                                  alpha: 0.92,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _imuActive
                                      ? Colors.deepPurple
                                      : AppColors.border,
                                  width: _imuActive ? 1.5 : 1.0,
                                ),
                              ),
                              child: Row(
                                children: [
                                  // Botones START/STOP + NORMAL/VOLANTE
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        onTap: _imuActive
                                            ? _stopImu
                                            : _startImu,
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 150,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _imuActive
                                                ? AppColors.danger
                                                : Colors.deepPurple,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                _imuActive
                                                    ? Icons.sensors_off
                                                    : Icons.sensors,
                                                color: Colors.white,
                                                size: 14,
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                _imuActive ? 'STOP' : 'START',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      // Toggle NORMAL / VOLANTE + bloqueo orientación
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _mode = _mode == _ImuMode.normal
                                                ? _ImuMode.volante
                                                : _ImuMode.normal;
                                          });
                                          _applyOrientation();
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.background,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: Colors.deepPurple,
                                            ),
                                          ),
                                          child: Text(
                                            _mode == _ImuMode.normal
                                                ? 'VERTICAL'
                                                : 'WHEEL',
                                            style: const TextStyle(
                                              color: Colors.deepPurple,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  // Horizonte artificial
                                  _AttitudeIndicator(
                                    pitch: _adiPitch,
                                    roll: _adiRoll,
                                    active: _imuActive,
                                    size: 64,
                                  ),
                                  const SizedBox(width: 12),
                                  // Gauges de zona muerta (incluye YAW)
                                  Expanded(child: _buildGaugesColumn()),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // --------- BARRA INFERIOR--------------
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: screenW * 0.01,
                vertical: screenH * 0.005,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildBottomButton(
                      icon: Icons.power_settings_new,
                      label: 'ARM',
                      enabled:
                          !provider.isLoading &&
                          provider.isConnected &&
                          !provider.isArmed &&
                          !provider.isFlying,
                      color: AppColors.warning,
                      onTap: () => context.read<DronProvider>().armDron(),
                    ),
                  ),
                  SizedBox(width: screenW * 0.01),
                  Expanded(
                    child: _buildBottomButton(
                      icon: Icons.flight_takeoff,
                      label: 'TAKEOFF',
                      enabled:
                          !provider.isLoading &&
                          provider.isConnected &&
                          provider.isArmed &&
                          !provider.isFlying,
                      color: AppColors.primary,
                      onTap: () => context.read<DronProvider>().takeOff(),
                    ),
                  ),
                  SizedBox(width: screenW * 0.01),
                  Expanded(
                    child: _buildBottomButton(
                      icon: Icons.link_off,
                      label: 'DISC',
                      enabled:
                          !provider.isLoading &&
                          provider.isConnected &&
                          !provider.isArmed &&
                          !provider.isFlying,
                      color: AppColors.danger,
                      outlined: true,
                      onTap: () {
                        context.read<DronProvider>().disconnectDron();
                        exitFullscreenEZ();
                        Navigator.pop(context);
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildBottomButton(
                      icon: Icons.flight_land,
                      label: 'LAND',
                      enabled:
                          !provider.isLoading &&
                          provider.isConnected &&
                          provider.isFlying,
                      color: AppColors.warning,
                      onTap: () => context.read<DronProvider>().land(),
                    ),
                  ),
                  SizedBox(width: screenW * 0.01),
                  Expanded(
                    child: _buildBottomButton(
                      icon: Icons.home,
                      label: 'RTL',
                      enabled:
                          !provider.isLoading &&
                          provider.isConnected &&
                          provider.isFlying,
                      color: AppColors.warning,
                      onTap: () => context.read<DronProvider>().rtl(),
                    ),
                  ),
                  SizedBox(width: screenW * 0.01),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Configuración de un gauge de zona muerta (visual, derivada del modo activo).
class _GaugeConfig {
  final String label;
  final double value;
  final double minDeg;
  final double maxDeg;
  final double deadLow;
  final double deadHigh;
  final Color accent;
  const _GaugeConfig(
    this.label,
    this.value,
    this.minDeg,
    this.maxDeg,
    this.deadLow,
    this.deadHigh,
    this.accent,
  );
}

// ── Horizonte artificial ──────────────────────────────────────────────────────
// Indicador de actitud tipo cabina: el horizonte se inclina con el roll (gamma)
// y sube/baja con el pitch (beta). La silueta central del avión queda fija.
class _AttitudeIndicator extends StatelessWidget {
  final double pitch; // beta
  final double roll; // gamma
  final bool active;
  final double size;

  const _AttitudeIndicator({
    required this.pitch,
    required this.roll,
    required this.active,
    this.size = 84,
  });

  @override
  Widget build(BuildContext context) {
    final Color ring = active ? Colors.cyan : AppColors.disabled;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 1.5),
        boxShadow: active
            ? [
                BoxShadow(
                  color: Colors.cyan.withValues(alpha: 0.25),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ClipOval(
        child: CustomPaint(
          painter: _AttitudePainter(pitch: pitch, roll: roll, active: active),
          size: Size(size, size),
        ),
      ),
    );
  }
}

class _AttitudePainter extends CustomPainter {
  final double pitch;
  final double roll;
  final bool active;

  _AttitudePainter({
    required this.pitch,
    required this.roll,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final pxPerDeg = size.height / 90.0;
    final dy = pitch.clamp(-45.0, 45.0) * pxPerDeg;

    final Color skyColor = active
        ? const Color(0xFF2C4A6E)
        : const Color(0xFF33384A);
    final Color groundColor = active
        ? const Color(0xFF5A3D26)
        : const Color(0xFF24242F);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-roll * pi / 180.0);

    final big = r * 3;
    // Cielo (arriba del horizonte) y tierra (abajo)
    canvas.drawRect(
      Rect.fromLTRB(-big, -big, big, dy),
      Paint()..color = skyColor,
    );
    canvas.drawRect(
      Rect.fromLTRB(-big, dy, big, big),
      Paint()..color = groundColor,
    );
    // Línea de horizonte
    canvas.drawLine(
      Offset(-big, dy),
      Offset(big, dy),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5,
    );
    // Escala de pitch (rungs) ±10° y ±20°
    final rung = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1;
    for (final deg in [10, 20]) {
      final half = deg == 10 ? r * 0.18 : r * 0.30;
      final yUp = dy - deg * pxPerDeg;
      final yDn = dy + deg * pxPerDeg;
      canvas.drawLine(Offset(-half, yUp), Offset(half, yUp), rung);
      canvas.drawLine(Offset(-half, yDn), Offset(half, yDn), rung);
    }
    canvas.restore();

    // Silueta fija del avión (no rota)
    final ac = Paint()
      ..color = active ? AppColors.warning : AppColors.disabled
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center + Offset(-r * 0.42, 0),
      center + Offset(-r * 0.12, 0),
      ac,
    );
    canvas.drawLine(
      center + Offset(r * 0.12, 0),
      center + Offset(r * 0.42, 0),
      ac,
    );
    canvas.drawCircle(center, 2.5, ac);
  }

  @override
  bool shouldRepaint(_AttitudePainter old) =>
      old.pitch != pitch || old.roll != roll || old.active != active;
}

// ── Gauge de zona muerta ──────────────────────────────────────────────────────
// Barra horizontal que muestra: banda central = zona muerta, marcador = posición
// actual del eje, y relleno coloreado = magnitud de salida cuando está fuera de
// la zona muerta. Es puramente informativo (no altera las rampas reales).
class _DeadZoneGauge extends StatelessWidget {
  final String label;
  final double value;
  final double minDeg;
  final double maxDeg;
  final double deadLow;
  final double deadHigh;
  final Color accent;
  final bool active;

  const _DeadZoneGauge({
    required this.label,
    required this.value,
    required this.minDeg,
    required this.maxDeg,
    required this.deadLow,
    required this.deadHigh,
    required this.accent,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: active ? accent : AppColors.textSecondary,
            fontSize: 7,
            letterSpacing: 1.0,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 12,
          width: double.infinity,
          child: CustomPaint(
            painter: _DeadZonePainter(
              value: value,
              minDeg: minDeg,
              maxDeg: maxDeg,
              deadLow: deadLow,
              deadHigh: deadHigh,
              accent: accent,
              active: active,
            ),
          ),
        ),
      ],
    );
  }
}

class _DeadZonePainter extends CustomPainter {
  final double value;
  final double minDeg;
  final double maxDeg;
  final double deadLow;
  final double deadHigh;
  final Color accent;
  final bool active;

  _DeadZonePainter({
    required this.value,
    required this.minDeg,
    required this.maxDeg,
    required this.deadLow,
    required this.deadHigh,
    required this.accent,
    required this.active,
  });

  double _map(double v, double width) {
    final t = ((v - minDeg) / (maxDeg - minDeg)).clamp(0.0, 1.0);
    return t * width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final radius = const Radius.circular(4);
    final fullRect = Offset.zero & size;

    // Track de fondo
    canvas.drawRRect(
      RRect.fromRectAndRadius(fullRect, radius),
      Paint()..color = AppColors.background,
    );

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(fullRect, radius));

    // Banda de zona muerta
    final dzL = _map(deadLow, size.width);
    final dzR = _map(deadHigh, size.width);
    canvas.drawRect(
      Rect.fromLTRB(dzL, 0, dzR, size.height),
      Paint()
        ..color = AppColors.disabled.withValues(alpha: active ? 0.55 : 0.3),
    );

    // Relleno de salida (magnitud fuera de la zona muerta)
    final v = value.clamp(minDeg, maxDeg);
    if (active && (v > deadHigh || v < deadLow)) {
      final from = v > deadHigh ? dzR : _map(v, size.width);
      final to = v > deadHigh ? _map(v, size.width) : dzL;
      canvas.drawRect(
        Rect.fromLTRB(from, 0, to, size.height),
        Paint()..color = accent.withValues(alpha: 0.5),
      );
    }

    // Marcador de posición actual
    final mx = _map(v, size.width);
    canvas.drawLine(
      Offset(mx, -1),
      Offset(mx, size.height + 1),
      Paint()
        ..color = active ? accent : AppColors.textSecondary
        ..strokeWidth = 2,
    );
    canvas.restore();

    // Borde
    canvas.drawRRect(
      RRect.fromRectAndRadius(fullRect, radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = AppColors.border
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DeadZonePainter old) =>
      old.value != value ||
      old.active != active ||
      old.deadLow != deadLow ||
      old.deadHigh != deadHigh ||
      old.minDeg != minDeg ||
      old.maxDeg != maxDeg;
}
