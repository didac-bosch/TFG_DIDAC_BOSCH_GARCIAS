import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/fullscreen.dart';

@JS('setDroneStreamRef')
external void _jsSetDroneStreamRef();

// ─────────────────────────────────────────────
//  Modos de panel Tello (extensible)
// ─────────────────────────────────────────────
enum _TelloMode { none, flip, follow, orbit }

class TelloFlightScreen extends StatefulWidget {
  const TelloFlightScreen({super.key});

  @override
  State<TelloFlightScreen> createState() => _TelloFlightScreenState();
}

class _TelloFlightScreenState extends State<TelloFlightScreen> {
  _TelloMode _activeMode = _TelloMode.none;

  void _toggleMode(_TelloMode mode) {
    setState(() {
      _activeMode = _activeMode == mode ? _TelloMode.none : mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final isPortrait = screenH > screenW;
    final joystickSize = isPortrait ? screenH * 0.18 : screenH * 0.36;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 1. VÍDEO fondo completo
          Positioned.fill(
            child: provider.remoteStream != null
                ? _VideoView(stream: provider.remoteStream!)
                : const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        'Waiting stream...',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ),
                  ),
          ),

          // ── 2. HUD SUPERIOR
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _HudBar(
              provider: provider,
              activeMode: _activeMode,
              onToggleMode: _toggleMode,
              onShowModeSelector: (ctx) {
                showModalBottomSheet(
                  context: ctx,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _ModeSelectorSheet(
                    activeMode: _activeMode,
                    onSelect: (mode) {
                      Navigator.pop(ctx);
                      _toggleMode(mode);
                    },
                  ),
                );
              },
              screenW: screenW,
              onDisconnect: () {
                exitFullscreenEZ();
                context.read<DronProvider>().disconnectDron();
                Navigator.pop(context);
              },
            ),
          ),

          // ── 3. PANEL DE MODO (overlay inferior)
          if (_activeMode != _TelloMode.none)
            Positioned(
              bottom: isPortrait ? joystickSize + 24 : 12,
              left: 0,
              right: 0,
              child: Center(
                child: _ModePanel(activeMode: _activeMode, provider: provider),
              ),
            ),

          // ── 4. JOYSTICK IZQUIERDO
          Positioned(
            left: 16,
            bottom: 16,
            top: null,
            child: isPortrait
                ? _TransparentJoystick(
                    size: joystickSize,
                    onMove: (x, y) => provider.isFlying
                        ? context.read<DronProvider>().updateJoystick(
                            lx: x,
                            ly: -y,
                          )
                        : null,
                    onRelease: () => context
                        .read<DronProvider>()
                        .updateJoystick(lx: 0, ly: 0),
                  )
                : Center(
                    child: _TransparentJoystick(
                      size: joystickSize,
                      onMove: (x, y) => provider.isFlying
                          ? context.read<DronProvider>().updateJoystick(
                              lx: x,
                              ly: -y,
                            )
                          : null,
                      onRelease: () => context
                          .read<DronProvider>()
                          .updateJoystick(lx: 0, ly: 0),
                    ),
                  ),
          ),

          // ── 5. JOYSTICK DERECHO
          Positioned(
            right: 16,
            bottom: 16,
            top: null,
            child: isPortrait
                ? _TransparentJoystick(
                    size: joystickSize,
                    onMove: (x, y) => provider.isFlying
                        ? context.read<DronProvider>().updateJoystick(
                            rx: x,
                            ry: -y,
                          )
                        : null,
                    onRelease: () => context
                        .read<DronProvider>()
                        .updateJoystick(rx: 0, ry: 0),
                  )
                : Center(
                    child: _TransparentJoystick(
                      size: joystickSize,
                      onMove: (x, y) => provider.isFlying
                          ? context.read<DronProvider>().updateJoystick(
                              rx: x,
                              ry: -y,
                            )
                          : null,
                      onRelease: () => context
                          .read<DronProvider>()
                          .updateJoystick(rx: 0, ry: 0),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  HELPER: bottom sheet de confirmación por slider
// ─────────────────────────────────────────────
void _showConfirmSlider(
  BuildContext context, {
  required String label,
  required Color color,
  required IconData icon,
  required VoidCallback onConfirmed,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConfirmSliderSheet(
      label: label,
      color: color,
      icon: icon,
      onConfirmed: () {
        Navigator.pop(context);
        onConfirmed();
      },
    ),
  );
}

// ─────────────────────────────────────────────
//  HUD SUPERIOR
// ─────────────────────────────────────────────
class _HudBar extends StatelessWidget {
  final DronProvider provider;
  final _TelloMode activeMode;
  final void Function(_TelloMode) onToggleMode;
  final void Function(BuildContext) onShowModeSelector;
  final double screenW;
  final VoidCallback onDisconnect;

  const _HudBar({
    required this.provider,
    required this.activeMode,
    required this.onToggleMode,
    required this.screenW,
    required this.onShowModeSelector,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final bat = provider.currentBat;
    final batColor = bat > 30
        ? AppColors.primary
        : bat > 15
        ? AppColors.warning
        : AppColors.danger;

    final bool canTakeoff =
        provider.isConnected && !provider.isFlying && !provider.isLoading;
    final bool canLand =
        provider.isConnected && provider.isFlying && !provider.isLoading;
    // DISCONNECT solo si conectado y NO volando (state == connected en TelloLink)
    final bool canDisconnect =
        provider.isConnected && !provider.isFlying && !provider.isLoading;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Izquierda: TAKEOFF + MODES
            _HudButton(
              icon: Icons.flight_takeoff,
              label: 'TAKEOFF',
              color: AppColors.primary,
              enabled: canTakeoff,
              onTap: () => _showConfirmSlider(
                context,
                label: 'TAKEOFF',
                color: AppColors.primary,
                icon: Icons.flight_takeoff,
                onConfirmed: () => context.read<DronProvider>().takeOff(),
              ),
            ),
            const SizedBox(width: 6),
            _HudButton(
              icon: Icons.tune,
              label: 'MODES',
              color: activeMode != _TelloMode.none
                  ? AppColors.warning
                  : AppColors.textSecondary,
              enabled: provider.isConnected,
              active: activeMode != _TelloMode.none,
              onTap: () => onShowModeSelector(context),
            ),

            // ── Centro: telemetría
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _HudStat(
                    icon: Icons.battery_full,
                    iconColor: batColor,
                    label: 'BAT',
                    value: '${bat.toInt()}%',
                    valueColor: batColor,
                  ),
                  _HudStat(
                    icon: Icons.height,
                    label: 'ALT',
                    value: '${provider.currentAlt.toStringAsFixed(1)}m',
                  ),
                  _HudStat(
                    icon: Icons.speed,
                    label: 'SPD',
                    value: '${provider.currentSpeed.toStringAsFixed(1)}m/s',
                  ),
                  if (provider.telloWifi != null)
                    _HudStat(
                      icon: Icons.wifi,
                      label: 'WiFi',
                      value: '${provider.telloWifi}',
                    ),
                  if (provider.telloTempC != null)
                    _HudStat(
                      icon: Icons.thermostat,
                      label: 'TEMP',
                      value: '${provider.telloTempC!.toStringAsFixed(0)}°C',
                    ),
                  if (provider.telloFlightTime != null)
                    _HudStat(
                      icon: Icons.timer,
                      label: 'TIME',
                      value: '${provider.telloFlightTime}s',
                    ),
                ],
              ),
            ),

            // ── Derecha: LAND + DISCONNECT
            _HudButton(
              icon: Icons.flight_land,
              label: 'LAND',
              color: AppColors.warning,
              enabled: canLand,
              onTap: () => _showConfirmSlider(
                context,
                label: 'LAND',
                color: AppColors.warning,
                icon: Icons.flight_land,
                onConfirmed: () => context.read<DronProvider>().land(),
              ),
            ),
            const SizedBox(width: 6),
            _HudButton(
              icon: Icons.link_off,
              label: 'DISC',
              color: AppColors.danger,
              enabled: canDisconnect,
              onTap: onDisconnect,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  PANEL DE MODOS
// ─────────────────────────────────────────────
class _ModePanel extends StatelessWidget {
  final _TelloMode activeMode;
  final DronProvider provider;

  const _ModePanel({required this.activeMode, required this.provider});

  @override
  Widget build(BuildContext context) {
    final IconData titleIcon = switch (activeMode) {
      _TelloMode.flip => Icons.flip_camera_android,
      _TelloMode.follow => Icons.directions_run,
      _TelloMode.orbit => Icons.rotate_right,
      _TelloMode.none => Icons.tune,
    };
    final String titleText = switch (activeMode) {
      _TelloMode.flip => 'FLIP MODE',
      _TelloMode.follow => 'FOLLOW MODE',
      _TelloMode.orbit => 'ORBIT MODE',
      _TelloMode.none => '',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(titleIcon, color: AppColors.warning, size: 14),
              const SizedBox(width: 6),
              Text(
                titleText,
                style: const TextStyle(
                  color: AppColors.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (activeMode == _TelloMode.flip) _FlipButtons(provider: provider),
          if (activeMode == _TelloMode.follow) ...[
            _FollowStatusBadge(
              status: provider.followStatus,
              tofDistance: provider.tofDistance,
            ),
            const SizedBox(height: 8),
            _FlipBtn(
              icon: provider.isFollowMode
                  ? Icons.directions_run
                  : Icons.directions_walk,
              label: provider.isFollowMode ? 'STOP' : 'START',
              enabled: provider.isFlying,
              onTap: () => context.read<DronProvider>().toggleFollowMode(),
            ),
          ],
          if (activeMode == _TelloMode.orbit) _OrbitButtons(provider: provider),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BOTONES DE FLIP (cruz)
// ─────────────────────────────────────────────
class _FlipButtons extends StatelessWidget {
  final DronProvider provider;
  const _FlipButtons({required this.provider});

  @override
  Widget build(BuildContext context) {
    final bool enabled = provider.isFlying;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FlipBtn(
          icon: Icons.arrow_upward,
          label: 'FWD',
          enabled: enabled,
          onTap: () => context.read<DronProvider>().sendFlip('forward'),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FlipBtn(
              icon: Icons.arrow_back,
              label: 'LEFT',
              enabled: enabled,
              onTap: () => context.read<DronProvider>().sendFlip('left'),
            ),
            const SizedBox(width: 32),
            _FlipBtn(
              icon: Icons.arrow_forward,
              label: 'RIGHT',
              enabled: enabled,
              onTap: () => context.read<DronProvider>().sendFlip('right'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _FlipBtn(
          icon: Icons.arrow_downward,
          label: 'BACK',
          enabled: enabled,
          onTap: () => context.read<DronProvider>().sendFlip('back'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  BOTONES DE ORBIT (rodear objeto)
// ─────────────────────────────────────────────
/// Panel de control para el modo órbita.
///
/// Permite al usuario elegir la dirección de rotación (CW / CCW),
/// ajustar el radio de la órbita y arrancar/detener la maniobra.
/// La lógica de vuelo real (sendOrbit, etc.) debe implementarse
/// en DronProvider cuando se conecte con el SDK del Tello.
class _OrbitButtons extends StatefulWidget {
  final DronProvider provider;
  const _OrbitButtons({required this.provider});

  @override
  State<_OrbitButtons> createState() => _OrbitButtonsState();
}

class _OrbitButtonsState extends State<_OrbitButtons> {
  double _radiusCm = 60;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.provider.isFlying;
    final bool isRunning = widget.provider.isOrbitMode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Fila: botones CW / STOP / CCW
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Órbita sentido antihorario
            _FlipBtn(
              icon: Icons.rotate_left,
              label: 'CCW',
              enabled: enabled && !isRunning,
              onTap: () => context.read<DronProvider>().startOrbit(
                radiusCm: _radiusCm.toInt(),
                clockwise: false,
              ),
            ),
            const SizedBox(width: 8),
            // Detener órbita
            _FlipBtn(
              icon: Icons.stop_circle_outlined,
              label: 'STOP',
              enabled: enabled && isRunning,
              onTap: () => context.read<DronProvider>().stopOrbit(),
            ),
            const SizedBox(width: 8),
            // Órbita sentido horario
            _FlipBtn(
              icon: Icons.rotate_right,
              label: 'CW',
              enabled: enabled && !isRunning,
              onTap: () => context.read<DronProvider>().startOrbit(
                radiusCm: _radiusCm.toInt(),
                clockwise: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ── Slider de radio
        SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'RADIO: ${_radiusCm.toInt()} cm',
                style: const TextStyle(
                  color: AppColors.warning,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.warning,
                  inactiveTrackColor: AppColors.warning.withValues(alpha: 0.2),
                  thumbColor: AppColors.warning,
                  overlayColor: AppColors.warning.withValues(alpha: 0.15),
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: _radiusCm,
                  min: 30,
                  max: 200,
                  divisions: 17, // pasos de 10 cm
                  onChanged: isRunning
                      ? null // no se puede cambiar mientras orbita
                      : (v) => setState(() => _radiusCm = v),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
//  BOTÓN GENÉRICO DE ACCIÓN (flip / orbit / follow)
// ─────────────────────────────────────────────
class _FlipBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _FlipBtn({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.warning.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled
                ? AppColors.warning.withValues(alpha: 0.7)
                : AppColors.disabled,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: enabled ? AppColors.warning : AppColors.disabled,
              size: 22,
            ),
            Text(
              label,
              style: TextStyle(
                color: enabled ? AppColors.warning : AppColors.disabled,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  JOYSTICK TRANSPARENTE
// ─────────────────────────────────────────────
class _TransparentJoystick extends StatelessWidget {
  final double size;
  final void Function(double x, double y)? onMove;
  final VoidCallback onRelease;

  const _TransparentJoystick({
    required this.size,
    required this.onMove,
    required this.onRelease,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.45,
      child: SizedBox(
        width: size,
        height: size,
        child: Joystick(
          mode: JoystickMode.all,
          listener: (details) {
            onMove?.call(details.x, details.y);
          },
          onStickDragEnd: onRelease,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  HUD STAT WIDGET
// ─────────────────────────────────────────────
class _HudStat extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;
  final Color? valueColor;

  const _HudStat({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor ?? AppColors.primary, size: 10),
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
            style: TextStyle(
              color: valueColor ?? AppColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  HUD BUTTON WIDGET
// ─────────────────────────────────────────────
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
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.25)
              : (enabled ? Colors.black54 : Colors.black26),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.8) : AppColors.disabled,
            width: active ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: enabled ? color : AppColors.disabled, size: 18),
            const SizedBox(height: 1),
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

// ─────────────────────────────────────────────
//  CONFIRM SLIDER SHEET
// ─────────────────────────────────────────────
/// Bottom sheet con slider deslizable que el usuario debe arrastrar
/// hasta el final para confirmar una acción crítica (TAKEOFF / LAND).
/// Si se suelta antes del 95 %, el thumb vuelve al inicio automáticamente.
class _ConfirmSliderSheet extends StatefulWidget {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onConfirmed;

  const _ConfirmSliderSheet({
    required this.label,
    required this.color,
    required this.icon,
    required this.onConfirmed,
  });

  @override
  State<_ConfirmSliderSheet> createState() => _ConfirmSliderSheetState();
}

class _ConfirmSliderSheetState extends State<_ConfirmSliderSheet> {
  double _value = 0.0;
  bool _confirmed = false;

  void _onChanged(double v) {
    if (_confirmed) return;
    setState(() => _value = v);
    if (v >= 0.95) {
      setState(() {
        _confirmed = true;
        _value = 1.0;
      });
      // Pequeño delay visual antes de ejecutar la acción
      Future.delayed(const Duration(milliseconds: 250), widget.onConfirmed);
    }
  }

  void _onChangeEnd(double v) {
    // Si no se llegó al umbral, rebota al inicio
    if (!_confirmed) {
      setState(() => _value = 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final displayLabel = _confirmed
        ? 'CONFIRMED!'
        : 'SLIDE TO  ${widget.label}';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xEE111111),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Cabecera
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: color, size: 18),
              const SizedBox(width: 8),
              Text(
                displayLabel,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // ── Slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 10,
              activeTrackColor: color.withValues(alpha: 0.85),
              inactiveTrackColor: color.withValues(alpha: 0.15),
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 18),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 26),
            ),
            child: Slider(
              value: _value,
              min: 0,
              max: 1,
              onChanged: _confirmed ? null : _onChanged,
              onChangeEnd: _onChangeEnd,
            ),
          ),
          const SizedBox(height: 8),
          // ── Hint
          if (!_confirmed)
            Text(
              'Arrastra hasta el final para confirmar',
              style: TextStyle(
                color: color.withValues(alpha: 0.55),
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  VIDEO VIEW (igual que flight_screen)
// ─────────────────────────────────────────────
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
          _jsSetDroneStreamRef();
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

// ─────────────────────────────────────────────
//  SELECTOR DE MODOS (bottom sheet)
// ─────────────────────────────────────────────
class _ModeSelectorSheet extends StatelessWidget {
  final _TelloMode activeMode;
  final void Function(_TelloMode) onSelect;
  const _ModeSelectorSheet({required this.activeMode, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xDD111111),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'SELECCIONA MODO',
            style: TextStyle(
              color: AppColors.warning,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ModeOption(
                icon: Icons.flip_camera_android,
                label: 'FLIP',
                active: activeMode == _TelloMode.flip,
                onTap: () => onSelect(_TelloMode.flip),
              ),
              _ModeOption(
                icon: Icons.directions_run,
                label: 'FOLLOW',
                active: activeMode == _TelloMode.follow,
                onTap: () => onSelect(_TelloMode.follow),
              ),
              _ModeOption(
                icon: Icons.rotate_right,
                label: 'ORBIT',
                active: activeMode == _TelloMode.orbit,
                onTap: () => onSelect(_TelloMode.orbit),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  OPCIÓN DE MODO (tarjeta del selector)
// ─────────────────────────────────────────────
class _ModeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ModeOption({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 90,
        height: 80,
        decoration: BoxDecoration(
          color: active
              ? AppColors.warning.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.warning : AppColors.disabled,
            width: active ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: active ? AppColors.warning : AppColors.disabled,
              size: 28,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? AppColors.warning : AppColors.disabled,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowStatusBadge extends StatelessWidget {
  final String status;
  final double tofDistance;
  const _FollowStatusBadge({required this.status, required this.tofDistance});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'following' => ('● FOLLOWING', const Color(0xFF00E676)),
      'tof' => ('● FOLLOWING (ToF)', const Color(0xFF00E676)),
      'searching' => ('⟳ SEARCHING 360°', AppColors.warning),
      'grace' => ('… HOLDING', const Color(0xFF29B6F6)),
      'lost' => ('x TARGET LOST', AppColors.danger),
      'waiting' => ('◌ WAITING', AppColors.textSecondary),
      _ => ('— OFF', AppColors.disabled),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.7), width: 1.2),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
        ),
        if (tofDistance > 0) ...[
          const SizedBox(height: 5),
          Text(
            'ToF: ${tofDistance.toStringAsFixed(0)} cm',
            style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ],
    );
  }
}
