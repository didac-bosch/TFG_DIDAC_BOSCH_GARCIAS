import 'dart:math';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/js_bridges.dart';
import 'dart:js_interop';

@JS('eval')
external void _jsEval(String code);

class FlightScreen extends StatefulWidget {
  const FlightScreen({super.key});

  @override
  State<FlightScreen> createState() => _FlightScreenState();
}

class _FlightScreenState extends State<FlightScreen> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    final bool isPortrait = screenH > screenW;
    final double joystickSize = isPortrait ? screenH * 0.17 : screenH * 0.35;

    Color getBatteryColor(double bat) {
      if (bat > 50) return AppColors.primary;
      if (bat > 20) return AppColors.warning;
      return AppColors.danger;
    }

    Widget joystickLeft = SizedBox(
      width: joystickSize,
      height: joystickSize,
      child: Joystick(
        mode: JoystickMode.all,
        listener: (details) {
          if (!provider.isFlying) return;
          context.read<DronProvider>().updateJoystick(
            lx: details.x,
            ly: -details.y,
          );
        },
        onStickDragEnd: () {
          context.read<DronProvider>().updateJoystick(lx: 0.0, ly: 0.0);
        },
      ),
    );

    Widget joystickRight = SizedBox(
      width: joystickSize,
      height: joystickSize,
      child: Joystick(
        mode: JoystickMode.all,
        listener: (details) {
          if (!provider.isFlying) return;
          context.read<DronProvider>().updateJoystick(
            rx: details.x,
            ry: details.y,
          );
        },
        onStickDragEnd: () {
          context.read<DronProvider>().updateJoystick(rx: 0.0, ry: 0.0);
        },
      ),
    );

    // Botón swap mapa / cámara
    Widget swapButton = GestureDetector(
      onTap: () => context.read<DronProvider>().toggleVideo(),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Icon(
          provider.isVideoActive ? Icons.map : Icons.videocam,
          color: AppColors.textPrimary,
          size: 16,
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // -----------BARRA TELEMETRIA-------------
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
                                  color: getBatteryColor(provider.currentBat),
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
                                color: getBatteryColor(provider.currentBat),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                ],
              ),
            ),

            //-------------ZONA CENTRAL------------------------------------
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: screenH * 0.01,
                  horizontal: screenW * 0.015,
                ),
                child: Stack(
                  children: [
                    // ------- Contenedor principal mapa/vídeo
                    Positioned.fill(
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
                              // -------- MAPA SATELITAL
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
                                                pi /
                                                180,
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
                                  ],
                                ),

                              // ----------CÁMARA WebRTC
                              if (provider.isVideoActive)
                                provider.remoteStream != null
                                    ? SizedBox.expand(
                                        child: _VideoView(
                                          stream: provider.remoteStream!,
                                        ),
                                      )
                                    : const Center(
                                        child: Text(
                                          'Waiting Stream...',
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),

                              // ----- Badge precisión GPS (solo en mapa)
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
                                      borderRadius: BorderRadius.circular(6),
                                    ),
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

                              // ------------ Mensaje estado (solo en mapa)
                              if (!provider.isVideoActive)
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth: screenW * 0.35,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: AppColors.disabled,
                                      ),
                                    ),
                                    child: Text(
                                      provider.message,
                                      textAlign: TextAlign.right,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),

                              // ------- Botones captura / grabación + switch cámara (solo en cámara)
                              if (provider.isVideoActive)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Row(
                                    children: [
                                      // 📷 Captura foto
                                      GestureDetector(
                                        onTap: () => context
                                            .read<DronProvider>()
                                            .capturePhoto(),
                                        child: Container(
                                          padding: const EdgeInsets.all(7),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(
                                              color: AppColors.disabled,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.camera_alt,
                                            color: AppColors.textPrimary,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // ⏺ Grabar / detener
                                      GestureDetector(
                                        onTap: () {
                                          if (provider.isRecording) {
                                            context
                                                .read<DronProvider>()
                                                .stopRecording();
                                          } else {
                                            context
                                                .read<DronProvider>()
                                                .startRecording();
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(7),
                                          decoration: BoxDecoration(
                                            color: provider.isRecording
                                                ? AppColors.danger
                                                : Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(
                                              color: provider.isRecording
                                                  ? AppColors.danger
                                                  : AppColors.disabled,
                                            ),
                                          ),
                                          child: Icon(
                                            provider.isRecording
                                                ? Icons.stop_circle
                                                : Icons.fiber_manual_record,
                                            color: AppColors.textPrimary,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // Cambiar cámara
                                      GestureDetector(
                                        onTap: () => context
                                            .read<DronProvider>()
                                            .switchCamera(),
                                        child: Container(
                                          padding: const EdgeInsets.all(7),
                                          decoration: BoxDecoration(
                                            color: provider.cameraIndex == 1
                                                ? AppColors.primary
                                                : Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(
                                              color: provider.cameraIndex == 1
                                                  ? AppColors.primary
                                                  : AppColors.disabled,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.cameraswitch,
                                            color: AppColors.textPrimary,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                              // ------ Badge REC
                              if (provider.isRecording &&
                                  provider.isVideoActive)
                                Positioned(
                                  bottom: 8,
                                  left: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.danger,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.circle,
                                          color: Colors.white,
                                          size: 8,
                                        ),
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
                                  ),
                                ),

                              // ------- BARRA DE ZOOM vertical (solo en cámara)
                              // Posición: lateral izquierdo, centrada verticalmente.
                              // Usa RotatedBox para que el Slider quede vertical
                              // con el máximo (5×) arriba y el mínimo (1×) abajo.
                              // ✅ PONER ESTO
                              if (provider.isVideoActive)
                                if (isPortrait)
                                  Positioned(
                                    left: 6,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: Container(
                                        width: 36,
                                        height: screenH * 0.35,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black45,
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          border: Border.all(
                                            color: AppColors.disabled,
                                          ),
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
                                                child: SliderTheme(
                                                  data: SliderTheme.of(context).copyWith(
                                                    trackHeight: 2,
                                                    thumbShape:
                                                        const RoundSliderThumbShape(
                                                          enabledThumbRadius: 6,
                                                        ),
                                                    overlayShape:
                                                        const RoundSliderOverlayShape(
                                                          overlayRadius: 10,
                                                        ),
                                                    activeTrackColor:
                                                        AppColors.primary,
                                                    inactiveTrackColor:
                                                        AppColors.disabled,
                                                    thumbColor:
                                                        AppColors.primary,
                                                    overlayColor:
                                                        AppColors.primary,
                                                  ),
                                                  child: Slider(
                                                    value: provider.zoomLevel,
                                                    min: 1.0,
                                                    max: 5.0,
                                                    divisions: 8,
                                                    onChanged: (v) => context
                                                        .read<DronProvider>()
                                                        .setZoom(v),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            const Icon(
                                              Icons.zoom_in,
                                              color: AppColors.textSecondary,
                                              size: 12,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  Positioned(
                                    left: 60,
                                    right: 60,
                                    bottom: 8,
                                    child: Container(
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black45,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: AppColors.disabled,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.zoom_out,
                                            color: AppColors.textSecondary,
                                            size: 12,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: SliderTheme(
                                              data: SliderTheme.of(context).copyWith(
                                                trackHeight: 2,
                                                thumbShape:
                                                    const RoundSliderThumbShape(
                                                      enabledThumbRadius: 6,
                                                    ),
                                                overlayShape:
                                                    const RoundSliderOverlayShape(
                                                      overlayRadius: 10,
                                                    ),
                                                activeTrackColor:
                                                    AppColors.primary,
                                                inactiveTrackColor:
                                                    AppColors.disabled,
                                                thumbColor: AppColors.primary,
                                                overlayColor: AppColors.primary,
                                              ),
                                              child: Slider(
                                                value: provider.zoomLevel,
                                                min: 1.0,
                                                max: 5.0,
                                                divisions: 8,
                                                onChanged: (v) => context
                                                    .read<DronProvider>()
                                                    .setZoom(v),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          const Icon(
                                            Icons.zoom_in,
                                            color: AppColors.textSecondary,
                                            size: 12,
                                          ),
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
                                    ),
                                  ),

                              // ---- Joysticks
                              if (isPortrait)
                                Positioned(
                                  left: 12,
                                  bottom: 12,
                                  child: joystickLeft,
                                )
                              else
                                Positioned(
                                  left: 12,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(child: joystickLeft),
                                ),

                              if (isPortrait)
                                Positioned(
                                  right: 12,
                                  bottom: 12,
                                  child: joystickRight,
                                )
                              else
                                Positioned(
                                  right: 12,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(child: joystickRight),
                                ),

                              // -------- Botón swap
                              if (isPortrait)
                                Positioned(
                                  right: 8,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(child: swapButton),
                                )
                              else
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: swapButton,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── Dropdown detección YOLO
                    if (provider.isVideoActive)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: _DetectionDropdown(
                          current: provider.detectionMode,
                          onChanged: (mode) => context
                              .read<DronProvider>()
                              .setDetectionMode(mode),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ------------------BARRA INFERIOR COMANDOS-------------
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
                              exitFullscreenEZ();
                              context.read<DronProvider>().disconnectDron();
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
}

// Inicializa el RTCVideoRenderer
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
      Future.delayed(const Duration(milliseconds: 300), () {
        try {
          _jsEval('''(function() {
          var videos = document.querySelectorAll('video');
          for (var v of videos) {
            if (v.srcObject && v.srcObject.getVideoTracks().length > 0) {
              window._droneStream = v.srcObject;
              break;
            }
          }
        })();''');
        } catch (_) {}
      });
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

// Dropdown detección YOLO
class _DetectionDropdown extends StatelessWidget {
  final DetectionMode current;
  final ValueChanged<DetectionMode> onChanged;

  const _DetectionDropdown({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.disabled),
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
          onChanged: (mode) {
            if (mode != null) onChanged(mode);
          },
        ),
      ),
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
