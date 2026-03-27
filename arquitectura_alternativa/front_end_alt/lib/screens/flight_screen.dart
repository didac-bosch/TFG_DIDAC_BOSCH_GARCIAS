import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class FlightScreen extends StatefulWidget {
  const FlightScreen({super.key});

  @override
  State<FlightScreen> createState() => _FlightScreenState();
}

class _FlightScreenState extends State<FlightScreen> {
  @override
  void initState() {
    super.initState();
    _exitFullscreen();
  }

  void _exitFullscreen() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    // Tamaño del joystick relativo a la pantalla — sin valores fijos

    Color getBatteryColor(double bat) {
      if (bat > 50) return AppColors.primary;
      if (bat > 20) return AppColors.warning;
      return AppColors.danger;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      // ← SIN appBar
      body: SafeArea(
        child: Column(
          children: [
            // BARRA SUPERIOR - telemetría y estado
            Container(
              color: AppColors.surface,
              padding: EdgeInsets.symmetric(
                horizontal: screenW * 0.01,
                vertical: screenH * 0.005,
              ),
              child: Row(
                children: [
                  // TELEMETRÍA IZQUIERDA
                  Expanded(
                    flex: 2,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        _buildTopTelemetry(
                          Icons.height,
                          'ALT',
                          '${provider.currentAlt.toStringAsFixed(1)}m',
                        ),
                        SizedBox(width: screenW * 0.01),
                        _buildTopTelemetry(
                          Icons.speed,
                          'GS',
                          '${provider.currentSpeed.toStringAsFixed(1)}m/s',
                        ),
                        SizedBox(width: screenW * 0.01),
                        _buildTopTelemetry(
                          Icons.explore,
                          'HDG',
                          '${provider.currentHeading.toInt()}°',
                        ),
                        SizedBox(width: screenW * 0.01),
                        _buildTopTelemetry(
                          Icons.location_on,
                          'LAT',
                          provider.currentLat.toStringAsFixed(5),
                        ),
                        SizedBox(width: screenW * 0.01),
                        _buildTopTelemetry(
                          Icons.location_searching,
                          'LON',
                          provider.currentLon.toStringAsFixed(5),
                        ),
                      ],
                    ),
                  ),

                  // CENTRO - mensaje
                  Expanded(
                    flex: 1,
                    child: Container(
                      margin: EdgeInsets.symmetric(horizontal: screenW * 0.008),
                      padding: EdgeInsets.symmetric(
                        vertical: screenH * 0.003,
                        horizontal: screenW * 0.005,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.disabled),
                      ),
                      child: Text(
                        provider.message,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyles.status.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),

                  // TELEMETRÍA DERECHA
                  Expanded(
                    flex: 2,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _buildTopTelemetry(
                          Icons.info_outline,
                          'STATE',
                          provider.currentState,
                        ),
                        SizedBox(width: screenW * 0.01),
                        _buildTopTelemetry(
                          Icons.airplanemode_active,
                          'MODE',
                          provider.currentMode,
                        ),
                        SizedBox(width: screenW * 0.01),
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
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.battery_full,
                                        color: getBatteryColor(
                                          provider.currentBat,
                                        ),
                                        size: 12,
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
                                      color: getBatteryColor(
                                        provider.currentBat,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ZONA MEDIA — joysticks + mapa/cámara
            Expanded(
              child: Row(
                children: [
                  // JOYSTICK IZQUIERDO
                  Flexible(
                    flex: 1,
                    child: Container(
                      color: AppColors.background,
                      child: Center(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = constraints.maxHeight * 0.55;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('ALT/YAW', style: TextStyles.status),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: size,
                                  height: size,
                                  child: Joystick(
                                    mode: JoystickMode.all,
                                    listener: (details) {
                                      if (!provider.isFlying) return;
                                      context
                                          .read<DronProvider>()
                                          .updateJoystick(
                                            lx: details.x,
                                            ly: -details.y,
                                          );
                                    },
                                    onStickDragEnd: () {
                                      context
                                          .read<DronProvider>()
                                          .updateJoystick(lx: 0.0, ly: 0.0);
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                  // ZONA CENTRAL — mapa o cámara
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: screenH * 0.01,
                        horizontal: screenW * 0.015,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.primary,
                            width: 2,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            children: [
                              // MAPA SATELITAL
                              if (!provider.isVideoActive)
                                FlutterMap(
                                  options: MapOptions(
                                    initialCenter: LatLng(
                                      provider.currentLat != 0.0
                                          ? provider.currentLat
                                          : 41.2765,
                                      provider.currentLon != 0.0
                                          ? provider.currentLon
                                          : 1.9888,
                                    ),
                                    initialZoom: 17,
                                  ),

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

                                    // Marcador del usuario
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
                                    if (provider.userPosition != null &&
                                        !provider.isVideoActive)
                                      Positioned(
                                        top: 10,
                                        left: 10,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black45,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.gps_fixed,
                                                size: 11,
                                                color:
                                                    provider.userAccuracy <= 5
                                                    ? Colors.green
                                                    : provider.userAccuracy <=
                                                          20
                                                    ? Colors.orange
                                                    : Colors.red,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                '${provider.userAccuracy.toStringAsFixed(1)} m',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      provider.userAccuracy <= 5
                                                      ? Colors.green
                                                      : provider.userAccuracy <=
                                                            20
                                                      ? Colors.orange
                                                      : Colors.red,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

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
                                    // DRON + FLECHA en un solo marker
                                    MarkerLayer(
                                      markers: [
                                        Marker(
                                          point: LatLng(
                                            provider.currentLat,
                                            provider.currentLon,
                                          ),
                                          width: 32,
                                          height: 48,
                                          child: Transform.rotate(
                                            angle:
                                                provider.currentHeading *
                                                (pi / 180),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.arrow_upward,
                                                  color: AppColors.warning,
                                                  size: 16,
                                                ),
                                                Image.asset(
                                                  'assets/images/drone_icon.png',
                                                  width: 24,
                                                  height: 24,
                                                  color: AppColors.primary,
                                                  colorBlendMode:
                                                      BlendMode.srcIn,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),

                              // CÁMARA
                              if (provider.isVideoActive)
                                provider.remoteStream != null
                                    ? SizedBox.expand(
                                        child: _VideoView(
                                          stream: provider.remoteStream!,
                                        ),
                                      )
                                    : const Center(
                                        child: Text(
                                          'Esperando stream...',
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),

                              // BOTÓN SWAP
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: GestureDetector(
                                  onTap: () => context
                                      .read<DronProvider>()
                                      .toggleVideo(),
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: AppColors.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: AppColors.disabled,
                                      ),
                                    ),
                                    child: Icon(
                                      provider.isVideoActive
                                          ? Icons.map
                                          : Icons.videocam,
                                      color: AppColors.textPrimary,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // JOYSTICK DERECHO
                  Flexible(
                    flex: 1,
                    child: Container(
                      color: AppColors.background,
                      child: Center(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = constraints.maxHeight * 0.55;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'PITCH/ROLL',
                                  style: TextStyles.status,
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: size,
                                  height: size,
                                  child: Joystick(
                                    mode: JoystickMode.all,
                                    listener: (details) {
                                      if (!provider.isFlying) return;
                                      context
                                          .read<DronProvider>()
                                          .updateJoystick(
                                            rx: details.x,
                                            ry: details.y,
                                          );
                                    },
                                    onStickDragEnd: () {
                                      context
                                          .read<DronProvider>()
                                          .updateJoystick(rx: 0.0, ry: 0.0);
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // BARRA INFERIOR
            Container(
              color: AppColors.surface,
              padding: EdgeInsets.symmetric(
                horizontal: screenW * 0.01,
                vertical: screenH * 0.008,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.power_settings_new, size: 16),
                      label: const Text(
                        'ARM',
                        style: TextStyles.button,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flight_takeoff, size: 16),
                      label: const Text(
                        'TAKEOFF',
                        style: TextStyles.button,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text(
                        'DISCONNECT',
                        style: TextStyles.button,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                              _exitFullscreen();
                              Navigator.pop(context);
                            },
                    ),
                  ),
                  SizedBox(width: screenW * 0.01),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.flight_land, size: 16),
                      label: const Text(
                        'LAND',
                        style: TextStyles.button,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.home, size: 16),
                      label: const Text(
                        'RTL',
                        style: TextStyles.button,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopTelemetry(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.primary, size: 12),
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
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class _VideoView extends StatefulWidget {
  final MediaStream stream;
  const _VideoView({required this.stream});

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      _renderer.srcObject = widget.stream;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      _renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }
}

LatLng _calcVelocityEndPoint(double lat, double lon, double vx, double vy) {
  final speed = sqrt(vx * vx + vy * vy);
  if (speed < 0.3) return LatLng(lat, lon);
  const scale = 6.0;
  final dlat = (vx * scale) / 111320;
  final dlon = (vy * scale) / (111320 * cos(lat * pi / 180));
  return LatLng(lat + dlat, lon + dlon);
}
