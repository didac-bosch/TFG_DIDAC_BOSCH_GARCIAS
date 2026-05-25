import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'flight_screen.dart';
import 'voice_flight_screen.dart';
import 'imu_flight_screen.dart';
import '../core/fullscreen.dart';
import 'flight_log_screen.dart';
import 'flight_plan_screen.dart';
import 'tello_flight_screen.dart';

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();

    // Mostrar error de conexión si se ha producido
    if (provider.connectionErrorMode != null) {
      final mode = provider.connectionErrorMode!;
      provider.clearConnectionError(); 
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return; // guard de safety
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Row(
              children: [
                Icon(Icons.error_outline, color: AppColors.danger, size: 20),
                SizedBox(width: 8),
                Text(
                  'Mode not available',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
              ],
            ),
            content: Text(
              '$mode mode is not reachable.\nCheck that the drone / simulator is running and try again.',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'OK',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      });
    }
    final mq = MediaQuery.of(context);
    final screenW = mq.size.width;
    final screenH = mq.size.height + mq.viewInsets.bottom;
    final isLandscape = screenH < screenW;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('EZDRONE', style: TextStyles.title),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FlightPlanScreen()),
            ),
            tooltip: 'Flight Planner',
            icon: const Icon(Icons.edit_location_alt_outlined, size: 22),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FlightLogScreen()),
            ),
            tooltip: 'Flight Log',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.history, size: 22),
                if (provider.flightHistory.isNotEmpty)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary,
                      ),
                      child: Center(
                        child: Text(
                          '${provider.flightHistory.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _showHelpSheet(context),
            tooltip: 'How to fly',
            icon: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 1.5),
              ),
              child: const Center(
                child: Text(
                  '?',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            final mq = MediaQuery.of(context);
            final isPortrait =
                (mq.size.height + mq.viewInsets.bottom) > mq.size.width;
            return isPortrait
                ? _buildPortrait(context, provider, screenW, screenH)
                : _buildLandscape(context, provider, screenW, screenH);
          },
        ),
      ),
    );
  }

  Widget _buildPortrait(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.symmetric(vertical: screenH * 0.02),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: screenH * 0.03),
          FaIcon(
            FontAwesomeIcons.helicopterSymbol,
            size: screenW * 0.2,
            color: provider.isConnected
                ? AppColors.primary
                : AppColors.textSecondary,
          ),
          SizedBox(height: screenH * 0.025),
          _StatusBox(screenW: screenW, screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.01),
          if (provider.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          SizedBox(height: screenH * 0.03),
          _ConfigFields(screenW: screenW),
          SizedBox(height: screenH * 0.025),
          // Selector modo de conexión (ArduPilot / SITL)
          _DroneConnectionModeSelector(screenW: screenW, provider: provider),
          SizedBox(height: screenH * 0.025),
          // Selector modo de control (Classic / Voice / IMU)
          _ModeSelector(screenW: screenW, provider: provider),
          SizedBox(height: screenH * 0.04),
          _ConnectButton(
            screenW: screenW,
            screenH: screenH,
            provider: provider,
          ),
          SizedBox(height: screenH * 0.015),
          _StartFlightButton(
            screenW: screenW,
            screenH: screenH,
            provider: provider,
          ),
          SizedBox(height: screenH * 0.015),
          _DisconnectButton(
            screenW: screenW,
            screenH: screenH,
            provider: provider,
          ),
          SizedBox(height: screenH * 0.02),
        ],
      ),
    );
  }

  Widget _buildLandscape(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: screenW * 0.04,
        vertical: screenH * 0.04,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FaIcon(
                  FontAwesomeIcons.helicopterSymbol,
                  size: screenH * 0.18,
                  color: provider.isConnected
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
                SizedBox(height: screenH * 0.025),
                _StatusBox(
                  screenW: screenW * 0.45,
                  screenH: screenH,
                  provider: provider,
                ),
                SizedBox(height: screenH * 0.02),
                if (provider.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: CircularProgressIndicator(color: AppColors.primary),
                  ),
                SizedBox(height: screenH * 0.02),
                _DroneConnectionModeSelector(
                  screenW: screenW * 0.45,
                  provider: provider,
                ),
                SizedBox(height: screenH * 0.02),
                _ModeSelector(screenW: screenW * 0.45, provider: provider),
              ],
            ),
          ),
          SizedBox(width: screenW * 0.04),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConfigFields(screenW: screenW * 0.5),
                SizedBox(height: screenH * 0.04),
                _ConnectButton(
                  screenW: screenW * 0.5,
                  screenH: screenH,
                  provider: provider,
                ),
                SizedBox(height: screenH * 0.02),
                _StartFlightButton(
                  screenW: screenW * 0.5,
                  screenH: screenH,
                  provider: provider,
                ),
                SizedBox(height: screenH * 0.02),
                _DisconnectButton(
                  screenW: screenW * 0.5,
                  screenH: screenH,
                  provider: provider,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Selector modo de CONEXIÓN (ArduPilot / SITL) ─────────────────────────────
// Bloqueado visualmente cuando isConnected == true.
class _DroneConnectionModeSelector extends StatelessWidget {
  final double screenW;
  final DronProvider provider;

  const _DroneConnectionModeSelector({
    required this.screenW,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final bool locked = provider.isConnected;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'DRONE MODE',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              if (locked) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.lock,
                  size: 11,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 3),
                const Text(
                  'disconnect to change',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 9,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Opacity(
            opacity: locked ? 0.45 : 1.0,
            child: Wrap(
              spacing: screenW * 0.03,
              runSpacing: 8,
              children: [
                _ConnectionChip(
                  label: 'ArduPilot',
                  icon: Icons.developer_board,
                  color: AppColors.primary,
                  mode: DroneConnectionMode.ardupilot,
                  selected: provider.droneConnectionMode,
                  enabled: !locked,
                  onTap: () => context
                      .read<DronProvider>()
                      .setDroneConnectionMode(DroneConnectionMode.ardupilot),
                ),
                _ConnectionChip(
                  label: 'SITL',
                  icon: Icons.computer,
                  color: Colors.orange,
                  mode: DroneConnectionMode.sitl,
                  selected: provider.droneConnectionMode,
                  enabled: !locked,
                  onTap: () => context
                      .read<DronProvider>()
                      .setDroneConnectionMode(DroneConnectionMode.sitl),
                ),
                _ConnectionChip(
                  label: 'Tello',
                  icon: Icons.flight,
                  color: Colors.lightBlue,
                  mode: DroneConnectionMode.tello,
                  selected: provider.droneConnectionMode,
                  enabled: !locked,
                  onTap: () => context
                      .read<DronProvider>()
                      .setDroneConnectionMode(DroneConnectionMode.tello),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final DroneConnectionMode mode;
  final DroneConnectionMode selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ConnectionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isSelected = mode == selected;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? color : AppColors.disabled,
            width: isSelected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status box ────────────────────────────────────────────────────────────────
class _StatusBox extends StatelessWidget {
  final double screenW;
  final double screenH;
  final DronProvider provider;

  const _StatusBox({
    required this.screenW,
    required this.screenH,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: screenW * 0.04,
          vertical: screenH * 0.015,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Text(
          provider.message,
          textAlign: TextAlign.center,
          style: TextStyles.status,
        ),
      ),
    );
  }
}

// ── Config fields (altitud / velocidad) ───────────────────────────────────────
class _ConfigFields extends StatefulWidget {
  final double screenW;
  const _ConfigFields({required this.screenW});

  @override
  State<_ConfigFields> createState() => _ConfigFieldsState();
}

class _ConfigFieldsState extends State<_ConfigFields> {
  late final TextEditingController _altCtrl;
  late final TextEditingController _speedCtrl;
  bool _altValid = true;
  bool _speedValid = true;

  @override
  void initState() {
    super.initState();
    final provider = context.read<DronProvider>();
    _altCtrl = TextEditingController(text: provider.takeoffAltitude.toString());
    _speedCtrl = TextEditingController(text: provider.flightSpeed.toString());
  }

  @override
  void dispose() {
    _altCtrl.dispose();
    _speedCtrl.dispose();
    super.dispose();
  }

  bool _checkAlt(String v) {
    final n = double.tryParse(v.replaceAll(',', '.'));
    return n != null && n >= 2.0 && n <= 50.0;
  }

  bool _checkSpeed(String v) {
    final n = double.tryParse(v.replaceAll(',', '.'));
    return n != null && n >= 1.0 && n <= 15.0;
  }

  @override
  Widget build(BuildContext context) {
    final isTello =
        context.watch<DronProvider>().droneConnectionMode ==
        DroneConnectionMode.tello;

    if (isTello) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'Tello takeoff altitude is fixed (~50 cm)',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.screenW * 0.05),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SizedBox(
            width: widget.screenW * 0.35,
            child: TextFormField(
              controller: _altCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Alt (m)',
                helperText: '2.0 - 50.0',
                helperStyle: TextStyle(
                  color: _altValid ? AppColors.textSecondary : AppColors.danger,
                  fontSize: 10,
                ),
                labelStyle: const TextStyle(color: AppColors.textSecondary),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.textSecondary),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: _altValid ? AppColors.primary : AppColors.danger,
                  ),
                ),
              ),
              onChanged: (v) {
                setState(() => _altValid = _checkAlt(v));
                context.read<DronProvider>().setAltitude(v);
              },
            ),
          ),
          SizedBox(
            width: widget.screenW * 0.35,
            child: TextFormField(
              controller: _speedCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Speed (m/s)',
                helperText: '1.0 - 15.0',
                helperStyle: TextStyle(
                  color: _speedValid
                      ? AppColors.textSecondary
                      : AppColors.danger,
                  fontSize: 10,
                ),
                labelStyle: const TextStyle(color: AppColors.textSecondary),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.textSecondary),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: _speedValid ? AppColors.primary : AppColors.danger,
                  ),
                ),
              ),
              onChanged: (v) {
                setState(() => _speedValid = _checkSpeed(v));
                context.read<DronProvider>().setSpeed(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Selector modo de CONTROL (Classic / Voice / IMU) ─────────────────────────
class _ModeSelector extends StatelessWidget {
  final double screenW;
  final DronProvider provider;

  const _ModeSelector({required this.screenW, required this.provider});

  @override
  Widget build(BuildContext context) {
    final bool isTello =
        provider.droneConnectionMode == DroneConnectionMode.tello;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CONTROL MODE',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: screenW * 0.03,
            runSpacing: 8,
            children: [
              _ModeChip(
                label: 'Classic',
                icon: Icons.sports_esports,
                color: AppColors.primary,
                mode: ControlMode.classic,
                selected: provider.selectedMode,
                onTap: () => context.read<DronProvider>().setControlMode(
                  ControlMode.classic,
                ),
              ),
              if (!isTello) ...[
                _ModeChip(
                  label: 'Voice',
                  icon: Icons.mic,
                  color: Colors.teal,
                  mode: ControlMode.voice,
                  selected: provider.selectedMode,
                  onTap: () => context.read<DronProvider>().setControlMode(
                    ControlMode.voice,
                  ),
                ),
                _ModeChip(
                  label: 'IMU',
                  icon: Icons.sensors,
                  color: Colors.deepPurple,
                  mode: ControlMode.imu,
                  selected: provider.selectedMode,
                  onTap: () => context.read<DronProvider>().setControlMode(
                    ControlMode.imu,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final ControlMode mode;
  final ControlMode selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isSelected = mode == selected;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? color : AppColors.disabled,
            width: isSelected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Botones ───────────────────────────────────────────────────────────────────

class _ConnectButton extends StatelessWidget {
  final double screenW;
  final double screenH;
  final DronProvider provider;

  const _ConnectButton({
    required this.screenW,
    required this.screenH,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: SizedBox(
        width: double.infinity,
        height: screenH * 0.07,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.link),
          label: const Text('CONNECT', style: TextStyles.button),
          style: ElevatedButton.styleFrom(
            backgroundColor: provider.isConnected
                ? AppColors.primary
                : AppColors.disabled,
            disabledBackgroundColor: AppColors.disabled,
            foregroundColor: AppColors.textPrimary,
            disabledForegroundColor: AppColors.textSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: provider.isLoading || provider.isConnected
              ? null
              : context.read<DronProvider>().connectDron,
        ),
      ),
    );
  }
}

class _StartFlightButton extends StatelessWidget {
  final double screenW;
  final double screenH;
  final DronProvider provider;

  const _StartFlightButton({
    required this.screenW,
    required this.screenH,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final bool enabled =
        !provider.isLoading && provider.isConnected && provider.isConfigValid && !provider.isFlying;

    final Color modeColor = switch (provider.selectedMode) {
      ControlMode.classic => AppColors.primary,
      ControlMode.voice => Colors.teal,
      ControlMode.imu => Colors.deepPurple,
    };

    final IconData modeIcon = switch (provider.selectedMode) {
      ControlMode.classic => Icons.flight_takeoff,
      ControlMode.voice => Icons.mic,
      ControlMode.imu => Icons.sensors,
    };

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: SizedBox(
        width: double.infinity,
        height: screenH * 0.07,
        child: ElevatedButton.icon(
          icon: Icon(modeIcon),
          label: const Text('START FLIGHT', style: TextStyles.button),
          style: ElevatedButton.styleFrom(
            backgroundColor: enabled ? modeColor : AppColors.disabled,
            disabledBackgroundColor: AppColors.disabled,
            foregroundColor: AppColors.textPrimary,
            disabledForegroundColor: AppColors.textSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: enabled
              ? () {
                  requestFullscreenEZ();
                  if (provider.droneConnectionMode ==
                      DroneConnectionMode.tello) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TelloFlightScreen(),
                      ),
                    );
                    return;
                  }
                  switch (provider.selectedMode) {
                    case ControlMode.classic:
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const FlightScreen()),
                      );
                    case ControlMode.voice:
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const VoiceFlightScreen(),
                        ),
                      );
                    case ControlMode.imu:
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ImuFlightScreen(),
                        ),
                      );
                  }
                }
              : null,
        ),
      ),
    );
  }
}

class _DisconnectButton extends StatelessWidget {
  final double screenW;
  final double screenH;
  final DronProvider provider;

  const _DisconnectButton({
    required this.screenW,
    required this.screenH,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
      child: SizedBox(
        width: double.infinity,
        height: screenH * 0.06,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.link_off, size: 18),
          label: const Text('DISCONNECT', style: TextStyles.button),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.danger,
            disabledBackgroundColor: AppColors.danger,
            foregroundColor: AppColors.textPrimary,
            disabledForegroundColor: AppColors.textSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: provider.isLoading || !provider.isConnected
              ? null
              : context.read<DronProvider>().disconnectDron,
        ),
      ),
    );
  }
}

// ── Help sheet ────────────────────────────────────────────────────────────────

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
                  'Camera on: 📷 capture or ⏺ record video',
                ),
                _HelpItem(
                  Icons.check_circle,
                  'Flow: ARM → TAKEOFF → fly → LAND or RTL',
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
                  'First tap 🎤 — grants microphone permission',
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
                  'Connect phone to Tello Wi-Fi before launching the app',
                ),
                _HelpItem(
                  Icons.sports_esports,
                  'Dual joystick — left: Throttle/Yaw · right: Pitch/Roll',
                ),
                _HelpItem(
                  Icons.flight_takeoff,
                  'TAKEOFF — arms and takes off automatically (~50 cm)',
                ),
                _HelpItem(
                  Icons.flight_land,
                  'LAND — smooth descent and motor stop',
                ),
                _HelpItem(
                  Icons.tune,
                  'MODES — opens Flip / Dance / Follow overlay panel',
                ),
                _HelpItem(
                  Icons.flip_camera_android,
                  'Flip: tap a direction arrow while flying to execute the flip',
                ),
                _HelpItem(
                  Icons.music_note,
                  'Dance: sends a preset choreography sequence',
                ),
                _HelpItem(
                  Icons.directions_run,
                  'Follow: activates person-tracking mode (tap STOP to deactivate)',
                ),
                _HelpItem(
                  Icons.warning_amber,
                  'Voice and IMU modes are not available for Tello',
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
