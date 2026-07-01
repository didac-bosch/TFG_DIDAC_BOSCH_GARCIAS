import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../provider.dart';
import '../core/styles.dart';
import '../core/js_bridges.dart';

@JS('setDroneStreamRef')
external void _jsSetDroneStreamRef();

enum _TelloMode { none, flip, follow, orbit }

class TelloFlightScreen extends StatefulWidget {
  const TelloFlightScreen({super.key});
  @override
  State<TelloFlightScreen> createState() => _TelloFlightScreenState();
}

class _TelloFlightScreenState extends State<TelloFlightScreen> {
  _TelloMode _activeMode = _TelloMode.none;
  // Flags previos del provider: distinguen "modo nunca iniciado" (flag siempre
  // false, esperando START) de "modo activo reseteado por la ET" (true→false).
  bool _prevFollow = false;
  bool _prevOrbit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<DronProvider>();
      // Precedencia explícita en una sola asignación: con dos setState, si ambos
      // flags estuvieran true el segundo pisaba al primero.
      final mode = p.isOrbitMode
          ? _TelloMode.orbit
          : p.isFollowMode
              ? _TelloMode.follow
              : _TelloMode.none;
      if (mode != _TelloMode.none) setState(() => _activeMode = mode);
    });
  }

  // Reconcilia el estado local con el provider: si la ET resetea follow/orbit
  // (topicLanded, topicDisconnected, batería…), _activeMode quedaría mostrando
  // un panel que ya no corresponde. El flip es puramente local y no se toca.
  void _reconcileMode(DronProvider p) {
    // Cerrar el panel SOLO en transición activo→inactivo (la ET reseteó un modo
    // que estaba en marcha: land/disconnect/batería). Si el flag lleva en false
    // esperando que el usuario pulse START, el panel debe permanecer abierto.
    final followReset =
        _activeMode == _TelloMode.follow && _prevFollow && !p.isFollowMode;
    final orbitReset =
        _activeMode == _TelloMode.orbit && _prevOrbit && !p.isOrbitMode;
    if (followReset || orbitReset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _activeMode = _TelloMode.none);
      });
    }
    _prevFollow = p.isFollowMode;
    _prevOrbit = p.isOrbitMode;
  }

  void _toggleMode(_TelloMode mode) {
    setState(() {
      _activeMode = _activeMode == mode ? _TelloMode.none : mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    _reconcileMode(provider);
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final isPortrait = screenH > screenW;
    final joystickSize = isPortrait ? screenH * 0.22 : screenH * 0.40;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. VÍDEO fondo completo
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

          // 2. HUD SUPERIOR
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

          // 3. PANEL DE MODO overlay inferior
          if (_activeMode != _TelloMode.none)
            Positioned(
              bottom: isPortrait ? joystickSize + 28 : 16,
              left: 0,
              right: 0,
              child: Center(
                child: _ModePanel(activeMode: _activeMode, provider: provider),
              ),
            ),

          // Badge REC
          if (provider.isRecording)
            Positioned(
              bottom: isPortrait ? joystickSize + 8 : 8,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 7),
                    SizedBox(width: 5),
                    Text(
                      'REC',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. JOYSTICK IZQUIERDO
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

          // 5. JOYSTICK DERECHO
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
// HELPER confirm slider
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
// BOTÓN CIRCULAR (estilo app Tello oficial)
// ─────────────────────────────────────────────
class _CircleHudBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;

  const _CircleHudBtn({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = activeColor ?? AppColors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? color.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.12),
          border: Border.all(
            color: active
                ? color.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.55),
            width: active ? 2.0 : 1.5,
          ),
        ),
        child: Icon(icon, color: active ? color : Colors.white, size: 20),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// HUD SUPERIOR
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
        ? Colors.white
        : bat > 15
        ? AppColors.warning
        : AppColors.danger;

    final bool canTakeoff =
        provider.isConnected && !provider.isFlying && !provider.isLoading;
    final bool canLand =
        provider.isConnected && provider.isFlying && !provider.isLoading;
    final bool canDisconnect =
        provider.isConnected && !provider.isFlying && !provider.isLoading;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Izquierda: TAKEOFF o LAND (alternante según isFlying) + MODES
              _CircleHudBtn(
                icon: provider.isFlying
                    ? Icons.flight_land
                    : Icons.flight_takeoff,
                activeColor: provider.isFlying
                    ? AppColors.warning
                    : AppColors.primary,
                active: provider.isConnected,
                onTap: provider.isFlying
                    ? (canLand
                          ? () => _showConfirmSlider(
                              context,
                              label: 'LAND',
                              color: AppColors.warning,
                              icon: Icons.flight_land,
                              onConfirmed: () =>
                                  context.read<DronProvider>().land(),
                            )
                          : () {})
                    : (canTakeoff
                          ? () => _showConfirmSlider(
                              context,
                              label: 'TAKEOFF',
                              color: AppColors.primary,
                              icon: Icons.flight_takeoff,
                              onConfirmed: () =>
                                  context.read<DronProvider>().takeOff(),
                            )
                          : () {}),
              ),
              const SizedBox(width: 10),
              _CircleHudBtn(
                icon: Icons.tune,
                active: activeMode != _TelloMode.none,
                activeColor: AppColors.warning,
                onTap: provider.isConnected
                    ? () => onShowModeSelector(context)
                    : () {},
              ),

              // Centro: telemetría pill
              Expanded(
                child: Center(
                  child: _TelemetryPill(provider: provider, batColor: batColor),
                ),
              ),

              // Derecha: DISCONNECT + Photo + Video
              _CircleHudBtn(
                icon: Icons.link_off,
                activeColor: AppColors.danger,
                onTap: canDisconnect ? onDisconnect : () {},
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _CircleHudBtn(
                    icon: Icons.camera_alt_outlined,
                    onTap: () => context.read<DronProvider>().capturePhoto(),
                  ),
                  const SizedBox(height: 6),
                  _CircleHudBtn(
                    icon: provider.isRecording
                        ? Icons.stop_rounded
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// TELEMETRÍA PILL (centro HUD)
// ─────────────────────────────────────────────
class _TelemetryPill extends StatelessWidget {
  final DronProvider provider;
  final Color batColor;
  const _TelemetryPill({required this.provider, required this.batColor});

  Widget _div() => Container(
    width: 1,
    height: 12,
    margin: const EdgeInsets.symmetric(horizontal: 7),
    color: Colors.white.withValues(alpha: 0.2),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC1A1A1A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.battery_full_rounded, color: batColor, size: 13),
          const SizedBox(width: 3),
          Text(
            '${provider.currentBat.toInt()}%',
            style: TextStyle(
              color: batColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          _div(),
          Text(
            'HS ',
            style: const TextStyle(color: Colors.white54, fontSize: 9),
          ),
          Text(
            '${provider.currentSpeed.toStringAsFixed(1)}m/s',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          _div(),
          Text(
            'H ',
            style: const TextStyle(color: Colors.white54, fontSize: 9),
          ),
          Text(
            '${provider.currentAlt.toStringAsFixed(1)}m',
            style: const TextStyle(
              color: Colors.white,
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
// PANEL DE MODOS
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
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xDD111111),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(titleIcon, color: AppColors.warning, size: 13),
              const SizedBox(width: 6),
              Text(
                titleText,
                style: const TextStyle(
                  color: AppColors.warning,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (activeMode == _TelloMode.flip) _FlipButtons(provider: provider),
          if (activeMode == _TelloMode.follow) ...[
            _FollowStatusBadge(
              status: provider.followStatus,
              tofDistance: provider.tofDistance,
            ),
            const SizedBox(height: 10),
            _ActionBtn(
              icon: provider.isFollowMode
                  ? Icons.directions_run
                  : Icons.directions_walk,
              label: provider.isFollowMode ? 'STOP' : 'START',
              enabled: provider.isFlying,
              color: AppColors.warning,
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
// BOTONES DE FLIP
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
        _ActionBtn(
          icon: Icons.arrow_upward,
          label: 'FWD',
          enabled: enabled,
          color: AppColors.warning,
          onTap: () => context.read<DronProvider>().sendFlip('forward'),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionBtn(
              icon: Icons.arrow_back,
              label: 'LEFT',
              enabled: enabled,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().sendFlip('left'),
            ),
            const SizedBox(width: 36),
            _ActionBtn(
              icon: Icons.arrow_forward,
              label: 'RIGHT',
              enabled: enabled,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().sendFlip('right'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _ActionBtn(
          icon: Icons.arrow_downward,
          label: 'BACK',
          enabled: enabled,
          color: AppColors.warning,
          onTap: () => context.read<DronProvider>().sendFlip('back'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// BOTONES DE ORBIT
// ─────────────────────────────────────────────
class _OrbitButtons extends StatefulWidget {
  final DronProvider provider;
  const _OrbitButtons({required this.provider});
  @override
  State<_OrbitButtons> createState() => _OrbitButtonsState();
}

class _OrbitButtonsState extends State<_OrbitButtons> {
  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.provider.isFlying;
    final bool isRunning = widget.provider.isOrbitMode;

    final orbitStatus = widget.provider.orbitStatus;
    final orbitTof = widget.provider.orbitTofDistance;
    final (orbitLabel, orbitColor) = switch (orbitStatus) {
      'orbiting' => ('● ORBITING', const Color(0xFF00E676)),
      'approach' => ('→ APPROACHING', const Color(0xFF29B6F6)),
      'aligning' => ('⟳ ALIGNING', AppColors.warning),
      'searching' => ('⟳ SEARCHING', AppColors.warning),
      'lost' => ('✕ TARGET LOST', AppColors.danger),
      'hover_safe' => ('⏸ HOVER SAFE', const Color(0xFF29B6F6)),
      'activating' => ('◌ ACTIVATING', AppColors.textSecondary),
      'off' => ('— OFF', AppColors.disabled),
      _ => ('◌ WAITING', AppColors.textSecondary),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── AÑADIR — badge ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: orbitColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: orbitColor.withValues(alpha: 0.7),
              width: 1.2,
            ),
          ),
          child: Text(
            orbitLabel,
            style: TextStyle(
              color: orbitColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
        ),
        if (orbitTof > 0) ...[
          const SizedBox(height: 4),
          Text(
            'ToF: ${orbitTof.toStringAsFixed(0)} cm',
            style: TextStyle(
              color: orbitColor.withValues(alpha: 0.9),
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionBtn(
              icon: Icons.rotate_left,
              label: 'CCW',
              enabled: enabled && !isRunning,
              color: AppColors.warning,
              onTap: () =>
                  context.read<DronProvider>().startOrbit(clockwise: false),
            ),
            const SizedBox(width: 10),
            _ActionBtn(
              icon: Icons.stop_circle_outlined,
              label: 'STOP',
              enabled: enabled && isRunning,
              color: AppColors.warning,
              onTap: () => context.read<DronProvider>().stopOrbit(),
            ),
            const SizedBox(width: 10),
            _ActionBtn(
              icon: Icons.rotate_right,
              label: 'CW',
              enabled: enabled && !isRunning,
              color: AppColors.warning,
              onTap: () =>
                  context.read<DronProvider>().startOrbit(clockwise: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Radio automático: la ET fija la distancia de órbita con el ToF del
        // dron a la persona; ya no hay slider de radio manual.
        const Text(
          'Radio automático (distancia actual)',
          style: TextStyle(
            color: AppColors.warning,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// BOTÓN DE ACCIÓN GENÉRICO
// ─────────────────────────────────────────────
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: enabled
                ? color.withValues(alpha: 0.65)
                : Colors.white.withValues(alpha: 0.12),
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: enabled ? color : Colors.white24, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: enabled ? color : Colors.white24,
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
// JOYSTICK TRANSPARENTE
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
      opacity: 0.55,
      child: SizedBox(
        width: size,
        height: size,
        child: Joystick(
          mode: JoystickMode.all,
          listener: (details) => onMove?.call(details.x, details.y),
          onStickDragEnd: onRelease,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CONFIRM SLIDER SHEET
// ─────────────────────────────────────────────
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
      Future.delayed(const Duration(milliseconds: 250), widget.onConfirmed);
    }
  }

  void _onChangeEnd(double v) {
    if (!_confirmed) setState(() => _value = 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final displayLabel = _confirmed ? 'CONFIRMED!' : 'SLIDE TO ${widget.label}';

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
          if (!_confirmed)
            Text(
              'Slide the knob to confirm',
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
// VIDEO VIEW
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
// SELECTOR DE MODOS (bottom sheet)
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
            'SELECT FLIGHT MODE',
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
// OPCIÓN DE MODO
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

// ─────────────────────────────────────────────
// FOLLOW STATUS BADGE
// ─────────────────────────────────────────────
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
      'lost' => ('✕ TARGET LOST', AppColors.danger),
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
