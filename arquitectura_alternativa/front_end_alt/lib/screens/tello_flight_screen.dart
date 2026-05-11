import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/fullscreen.dart';

@JS('eval')
external void _jsEval(String code);

// ─────────────────────────────────────────────
//  Modos de panel Tello (extensible)
// ─────────────────────────────────────────────
enum _TelloMode { none, flip, dance, follow }

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
              onTap: () => context.read<DronProvider>().takeOff(),
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
              onTap: () => context.read<DronProvider>().land(),
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
    final IconData titleIcon = activeMode == _TelloMode.flip
        ? Icons.flip_camera_android
        : activeMode == _TelloMode.follow
            ? Icons.directions_run
            : Icons.music_note;

    final String titleText = activeMode == _TelloMode.flip
        ? 'FLIP MODE'
        : activeMode == _TelloMode.follow
            ? 'FOLLOW MODE'
            : 'DANCE MODE';

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
          // Título del modo activo
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
          if (activeMode == _TelloMode.dance) _DanceButtons(provider: provider),
          if (activeMode == _TelloMode.follow)
            _FlipBtn(
              icon: provider.isFollowMode
                  ? Icons.directions_run
                  : Icons.directions_walk,
              label: provider.isFollowMode ? 'STOP' : 'START',
              enabled: provider.isFlying,
              onTap: () => context.read<DronProvider>().toggleFollowMode(),
            ),
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
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }
}

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
                icon: Icons.music_note,
                label: 'DANCE',
                active: activeMode == _TelloMode.dance,
                onTap: () => onSelect(_TelloMode.dance),
              ),
              _ModeOption(
                icon: Icons.directions_run,
                label: 'FOLLOW',
                active: activeMode == _TelloMode.follow,
                onTap: () => onSelect(_TelloMode.follow),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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

class _DanceButtons extends StatelessWidget {
  final DronProvider provider;
  const _DanceButtons({required this.provider});

  @override
  Widget build(BuildContext context) {
    final bool enabled = provider.isFlying;
    return _FlipBtn(
      icon: Icons.music_note,
      label: 'DANCE',
      enabled: enabled,
      onTap: () => context.read<DronProvider>().sendDance(),
    );
  }
}
