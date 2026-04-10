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
import '../core/fullscreen.dart';

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
      ly: _lyButton,
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
    if (speed < 0.3) return LatLng(lat, lon);
    const scale = 6.0;
    final dlat = (vx * scale) / 111320;
    final dlon = (vy * scale) / (111320 * cos(lat * pi / 180));
    return LatLng(lat + dlat, lon + dlon);
  }

  // Colores batería
  Color _getBatteryColor(double bat) {
    if (bat > 50) return AppColors.primary;
    if (bat > 20) return AppColors.warning;
    return AppColors.danger;
  }

  // Recuadro ángulos
  Widget _buildAngleBox(
    String label,
    double value,
    Color color, {
    double fontSize = 9,
    double valueFontSize = 11,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _imuActive ? color : AppColors.disabled,
          width: _imuActive ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: _imuActive ? color : AppColors.textSecondary,
              fontSize: fontSize,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${value.toStringAsFixed(1)}°',
            style: TextStyle(
              color: _imuActive ? color : AppColors.textSecondary,
              fontSize: valueFontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // Widger botón altitud reutilizable
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
        setState(
          () => _lyButton = up ? 1.0 : -1.0,
        ); // ← setState, no updateJoystick
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
          color: isFlying ? Colors.black54 : Colors.black26,
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

  // Flecha de velocidad creciente (solo portrait)
  // El icono crece y rota según la velocidad y dirección del dron.
  Widget _buildVelocityArrow(double vx, double vy) {
    final speed = sqrt(vx * vx + vy * vy);
    final angle = atan2(vy, vx);
    final bool moving = speed > 0.3;
    const double maxSize = 22.0;
    final double norm = (speed / 5.0).clamp(0.0, 1.0);
    final double arrowSz = (maxSize * norm).clamp(8.0, maxSize);
    const green = Color.fromARGB(255, 0, 255, 132);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: moving ? 1.0 : 0.5,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.black54,
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

  // Widget reutilizable para cada celda de la barra de telemetría.
  Widget _buildTelemetryItem(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary, size: 11),
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 9,
              ),
            ),
          ],
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // Panel IMU
  Widget _buildLandscapeImuPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _imuActive ? Colors.deepPurple : AppColors.disabled,
          width: _imuActive ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Ángulos
          _buildAngleBox(
            'PITCH',
            _pitch,
            Colors.cyan,
            fontSize: 7,
            valueFontSize: 10,
          ),
          const SizedBox(height: 4),
          _buildAngleBox(
            'ROLL',
            _roll,
            Colors.lightBlue,
            fontSize: 7,
            valueFontSize: 10,
          ),
          const SizedBox(height: 4),
          _buildAngleBox(
            'YAW',
            _yaw,
            Colors.orange,
            fontSize: 7,
            valueFontSize: 10,
          ),
          const SizedBox(height: 8),
          // Botón START / STOP IMU
          GestureDetector(
            onTap: _imuActive ? _stopImu : _startImu,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _imuActive ? AppColors.danger : Colors.deepPurple,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 4),
          // Toggle NORMAL / VOLANTE — también bloquea orientación
          GestureDetector(
            onTap: () => setState(
              () => _mode = _mode == _ImuMode.normal
                  ? _ImuMode.volante
                  : _ImuMode.normal,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.deepPurple),
              ),
              child: Text(
                _mode == _ImuMode.normal ? '📱 NRM' : '🕹️ VOL',
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
            // --------- BARRA SUPERIOR DE TELEMETRÍA ------------------
            Container(
              color: AppColors.surface,
              padding: EdgeInsets.symmetric(
                horizontal: screenW * 0.015,
                vertical: screenH * 0.006,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildTelemetryItem(
                    Icons.height,
                    'ALT',
                    '${provider.currentAlt.toStringAsFixed(1)}m',
                  ),
                  _buildTelemetryItem(
                    Icons.speed,
                    'GS',
                    '${provider.currentSpeed.toStringAsFixed(1)}m/s',
                  ),
                  _buildTelemetryItem(
                    Icons.explore,
                    'HDG',
                    '${provider.currentHeading.toInt()}°',
                  ),
                  _buildTelemetryItem(
                    Icons.location_on,
                    'LAT',
                    provider.currentLat.toStringAsFixed(5),
                  ),
                  _buildTelemetryItem(
                    Icons.location_searching,
                    'LON',
                    provider.currentLon.toStringAsFixed(5),
                  ),
                  _buildTelemetryItem(
                    Icons.info_outline,
                    'STATE',
                    provider.currentState,
                  ),
                  _buildTelemetryItem(
                    Icons.airplanemode_active,
                    'MODE',
                    provider.currentMode,
                  ),
                  // Batería con color semáforo
                  provider.isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                            strokeWidth: 2,
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.battery_full,
                                  color: _getBatteryColor(provider.currentBat),
                                  size: 11,
                                ),
                                const SizedBox(width: 2),
                                const Text(
                                  'BAT',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              '${provider.currentBat.toInt()}%',
                              style: TextStyle(
                                color: _getBatteryColor(provider.currentBat),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                ],
              ),
            ),

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
                                        provider.currentVx / 100,
                                        provider.currentVy / 100,
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
                            // Sombra gris en la posición del dron
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

                        // ----------- Mensaje de estado del provider ----------
                        Positioned(
                          top: 10,
                          left: screenW * 0.06,
                          right: screenW * 0.10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.disabled),
                            ),
                            child: Text(
                              provider.message,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
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

                        // ----- Derecha mapa
                        Positioned(
                          right: 8,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: isPortrait
                                ? (provider.isFlying
                                      ? _buildVelocityArrow(
                                          provider.currentVx,
                                          provider.currentVy,
                                        )
                                      : const SizedBox.shrink())
                                : _buildLandscapeImuPanel(),
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
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _imuActive
                                      ? Colors.deepPurple
                                      : AppColors.disabled,
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
                                            color: Colors.black45,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: Colors.deepPurple,
                                            ),
                                          ),
                                          child: Text(
                                            _mode == _ImuMode.normal
                                                ? '📱 NORMAL'
                                                : '🕹️ VOLANTE',
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
                                  // Ángulos PITCH / ROLL / YAW — siempre visibles
                                  Expanded(
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        _buildAngleBox(
                                          'PITCH',
                                          _pitch,
                                          Colors.cyan,
                                          fontSize: 7,
                                          valueFontSize: 10,
                                        ),
                                        _buildAngleBox(
                                          'ROLL',
                                          _roll,
                                          Colors.lightBlue,
                                          fontSize: 7,
                                          valueFontSize: 10,
                                        ),
                                        _buildAngleBox(
                                          'YAW',
                                          _yaw,
                                          Colors.orange,
                                          fontSize: 7,
                                          valueFontSize: 10,
                                        ),
                                      ],
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
              ),
            ),

            // --------- BARRA INFERIOR--------------
            Container(
              color: AppColors.surface,
              padding: EdgeInsets.symmetric(
                horizontal: screenW * 0.01,
                vertical: screenH * 0.005,
              ),
              child: Row(
                children: [
                  // ARM — deshabilitado si ya está armado, volando o cargando
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.power_settings_new, size: 16),
                      label: const Text(
                        'ARM',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: provider.isArmed
                            ? AppColors.danger
                            : AppColors.warning,
                        disabledBackgroundColor: AppColors.disabled,
                        foregroundColor: AppColors.textPrimary,
                        disabledForegroundColor: AppColors.textSecondary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed:
                          provider.isLoading ||
                              !provider.isConnected ||
                              provider.isArmed ||
                              provider.isFlying
                          ? null
                          : () => context.read<DronProvider>().armDron(),
                    ),
                  ),

                  SizedBox(width: screenW * 0.01),

                  // TAKEOFF
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flight_takeoff, size: 16),
                      label: const Text(
                        'TAKEOFF',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
                      onPressed:
                          provider.isLoading ||
                              !provider.isConnected ||
                              !provider.isArmed ||
                              provider.isFlying
                          ? null
                          : () => context.read<DronProvider>().takeOff(),
                    ),
                  ),

                  SizedBox(width: screenW * 0.01),

                  //LAND
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flight_land, size: 16),
                      label: const Text(
                        'LAND',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
                      onPressed:
                          provider.isLoading ||
                              !provider.isConnected ||
                              !provider.isFlying
                          ? null
                          : () => context.read<DronProvider>().land(),
                    ),
                  ),

                  SizedBox(width: screenW * 0.01),

                  //RTL
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.home, size: 16),
                      label: const Text(
                        'RTL',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
                      onPressed:
                          provider.isLoading ||
                              !provider.isConnected ||
                              !provider.isFlying
                          ? null
                          : () => context.read<DronProvider>().rtl(),
                    ),
                  ),

                  SizedBox(width: screenW * 0.01),

                  // DISCONNECT — sale de fullscreen, desconecta y vuelve al SetupScreen
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text(
                        'DISC',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
                      onPressed:
                          provider.isLoading ||
                              !provider.isConnected ||
                              provider.isArmed ||
                              provider.isFlying
                          ? null
                          : () {
                              context.read<DronProvider>().disconnectDron();
                              exitFullscreenEZ();
                              Navigator.pop(context);
                            },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
