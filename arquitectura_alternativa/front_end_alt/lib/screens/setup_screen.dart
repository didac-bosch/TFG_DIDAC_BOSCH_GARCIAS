import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'flight_screen.dart';
import 'voice_flight_screen.dart';
import 'imu_flight_screen.dart';
import '../core/js_bridges.dart';
import 'flight_log_screen.dart';
import 'flight_plan_screen.dart';
import 'tello_flight_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SetupScreen — pantalla de entrada de EZDrone (la que abre main.dart).
//
// Aquí se elige QUÉ dron (ArduPilot / SITL / Tello) y CÓMO se va a pilotar
// (Classic / Voice / IMU), se configuran altitud y velocidad, y se conecta.
// El botón START FLIGHT es el que decide a cuál de las cinco pantallas de vuelo
// se navega. Desde la AppBar se llega además al planificador y al historial.
// ─────────────────────────────────────────────────────────────────────────────

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();

    // Si el intento de conexión falló, el provider deja aquí el modo que falló.
    // El diálogo no puede abrirse durante el build (estaríamos modificando el
    // árbol mientras se construye), así que se aplaza al final del frame.
    if (provider.connectionErrorMode != null) {
      final mode = provider.connectionErrorMode!;
      provider.clearConnectionError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
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

    // Se suma viewInsets.bottom para recuperar la altura real de la pantalla:
    // al abrirse el teclado, size.height se encoge y sin esto la app creería
    // que ha girado a horizontal.
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFF3A3A50)),
        ),
        // Accesos que no dependen de estar conectado: planificador, historial y ayuda
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FlightPlanScreen()),
            ),
            tooltip: 'Flight Planner',
            icon: const Icon(Icons.edit_location_alt_outlined, size: 22),
          ),
          // El icono del historial lleva una chapa con el nº de vuelos guardados
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
      // Mismo contenido en dos disposiciones: en vertical va todo apilado y en
      // horizontal en dos columnas, para que quepa sin scroll en el móvil.
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

  // Vertical: una sola columna con scroll. Todas las medidas son porcentajes de
  // la pantalla, así el diseño se adapta a cualquier móvil sin valores fijos.
  Widget _buildPortrait(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    final pad = screenW * 0.05;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.symmetric(horizontal: pad, vertical: screenH * 0.02),
      child: Column(
        children: [
          SizedBox(height: screenH * 0.015),
          _HeroSection(screenW: screenW, screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.02),
          _SectionCard(child: _DroneConnectionModeSelector(provider: provider)),
          SizedBox(height: screenH * 0.015),
          _SectionCard(child: _ModeSelector(provider: provider)),
          SizedBox(height: screenH * 0.015),
          _SectionCard(child: _ConfigFields(screenW: screenW - pad * 2)),
          SizedBox(height: screenH * 0.03),
          _ConnectButton(screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.013),
          _StartFlightButton(screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.013),
          _DisconnectButton(screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.02),
        ],
      ),
    );
  }

  // Horizontal: selectores a la izquierda, parámetros y botones a la derecha.
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
              children: [
                _HeroSection(
                  screenW: screenW * 0.4,
                  screenH: screenH,
                  provider: provider,
                ),
                SizedBox(height: screenH * 0.025),
                _SectionCard(
                  child: _DroneConnectionModeSelector(provider: provider),
                ),
                SizedBox(height: screenH * 0.02),
                _SectionCard(child: _ModeSelector(provider: provider)),
              ],
            ),
          ),
          SizedBox(width: screenW * 0.04),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SectionCard(child: _ConfigFields(screenW: screenW * 0.5)),
                SizedBox(height: screenH * 0.035),
                _ConnectButton(screenH: screenH, provider: provider),
                SizedBox(height: screenH * 0.02),
                _StartFlightButton(screenH: screenH, provider: provider),
                SizedBox(height: screenH * 0.02),
                _DisconnectButton(screenH: screenH, provider: provider),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section Card ──────────────────────────────────────────────────────────────
// Marco gris reutilizable: da el mismo aspecto a cada bloque de la pantalla.

class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3A3A50)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

// ── Hero Section ──────────────────────────────────────────────────────────────
// Cabecera: logo, nombre y el estado actual de la conexión. El punto de color y
// el icono cambian solos porque el provider notifica en cada cambio de estado.

class _HeroSection extends StatelessWidget {
  final double screenW;
  final double screenH;
  final DronProvider provider;

  const _HeroSection({
    required this.screenW,
    required this.screenH,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    // Semáforo del estado: naranja conectando, verde conectado, gris parado
    final Color dotColor = provider.isLoading
        ? AppColors.warning
        : provider.isConnected
        ? AppColors.primary
        : AppColors.disabled;

    // Proporcional a la pantalla pero con topes, para que no salga diminuto en
    // un móvil estrecho ni gigante en un monitor.
    final double iconSize = (screenW * 0.15).clamp(44.0, 80.0);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: screenH * 0.025, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A3A50)),
      ),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: provider.isConnected
                  ? AppColors.primary.withValues(alpha: 0.1)
                  : AppColors.background,
              border: Border.all(
                color: provider.isConnected
                    ? AppColors.primary
                    : AppColors.disabled,
                width: provider.isConnected ? 2.0 : 1.0,
              ),
            ),
            child: FaIcon(
              FontAwesomeIcons.helicopterSymbol,
              size: iconSize,
              color: provider.isConnected
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'EZDRONE',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ground Control Station',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
              letterSpacing: 2.5,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                provider.message,
                textAlign: TextAlign.center,
                style: TextStyles.status,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Drone Connection Mode Selector ────────────────────────────────────────────
// Elige el vehículo: ArduPilot (dron real), SITL (simulador) o Tello. Esta
// elección viaja por MQTT a la estación de tierra (topic setMode) y determina
// con qué librería hablará: dronLink o TelloLink.

class _DroneConnectionModeSelector extends StatelessWidget {
  final DronProvider provider;

  const _DroneConnectionModeSelector({required this.provider});

  @override
  Widget build(BuildContext context) {
    // Con el dron ya conectado no se puede cambiar de vehículo: habría que
    // desconectar antes, porque la estación de tierra ya tiene una sesión abierta.
    final bool locked = provider.isConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.developer_board,
              size: 14,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
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
              const Icon(Icons.lock, size: 11, color: AppColors.textSecondary),
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
        const SizedBox(height: 12),
        Opacity(
          opacity: locked ? 0.45 : 1.0,
          child: Wrap(
            spacing: 8,
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
    );
  }
}

// Píldora seleccionable de vehículo. Se pinta con el color del modo cuando está
// elegida y en gris cuando no.
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.12)
              : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : AppColors.disabled,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? color : AppColors.textSecondary,
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

// ── Control Mode Selector ─────────────────────────────────────────────────────
// Elige CÓMO se pilota: joystick en pantalla (Classic), por voz (Voice) o
// inclinando el móvil (IMU). A diferencia del selector de vehículo, esto no sale
// de la app: solo decide a qué pantalla de vuelo se navega.

class _ModeSelector extends StatelessWidget {
  final DronProvider provider;

  const _ModeSelector({required this.provider});

  @override
  Widget build(BuildContext context) {
    // El Tello tiene su propia pantalla (con flip, follow, orbit y panorámica),
    // así que voz e IMU no se ofrecen en ese modo.
    final bool isTello =
        provider.droneConnectionMode == DroneConnectionMode.tello;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.tune, size: 14, color: AppColors.textSecondary),
            SizedBox(width: 6),
            Text(
              'CONTROL MODE',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.12)
              : AppColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : AppColors.disabled,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? color : AppColors.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? color : AppColors.textSecondary,
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

// ── Config Fields ─────────────────────────────────────────────────────────────
// Altitud de despegue y velocidad de navegación. Es StatefulWidget porque
// necesita sus propios TextEditingController y una copia local de "el valor es
// válido" para poner el campo en rojo mientras se escribe. La validación que
// manda sigue siendo la del provider; esta solo es el aviso visual.

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

  // Rangos permitidos. El replaceAll acepta la coma decimal: en un teclado en
  // español se escribe "7,5" y double.tryParse solo entiende el punto.
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

    const header = Row(
      children: [
        Icon(Icons.tune_rounded, size: 14, color: AppColors.textSecondary),
        SizedBox(width: 6),
        Text(
          'FLIGHT PARAMETERS',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );

    // El Tello despega siempre a la misma altura y no acepta velocidad de
    // navegación, así que en ese modo no se muestran los campos.
    if (isTello) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          header,
          SizedBox(height: 12),
          Text(
            'Tello takeoff altitude is fixed (~50 cm)',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _altCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.background,
                  labelText: 'Alt (m)',
                  helperText: '2.0 – 50.0',
                  helperStyle: TextStyle(
                    color: _altValid
                        ? AppColors.textSecondary
                        : AppColors.danger,
                    fontSize: 10,
                  ),
                  labelStyle: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  prefixIcon: Icon(
                    Icons.height,
                    color: _altValid
                        ? AppColors.textSecondary
                        : AppColors.danger,
                    size: 18,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: _altValid ? AppColors.disabled : AppColors.danger,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: _altValid ? AppColors.primary : AppColors.danger,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                // Dos cosas en cada pulsación: repintar el campo (rojo/normal) y
                // pasar el valor al provider, que lo valida por su cuenta.
                onChanged: (v) {
                  setState(() => _altValid = _checkAlt(v));
                  context.read<DronProvider>().setAltitude(v);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _speedCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: AppColors.background,
                  labelText: 'Speed (m/s)',
                  helperText: '1.0 – 15.0',
                  helperStyle: TextStyle(
                    color: _speedValid
                        ? AppColors.textSecondary
                        : AppColors.danger,
                    fontSize: 10,
                  ),
                  labelStyle: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  prefixIcon: Icon(
                    Icons.speed,
                    color: _speedValid
                        ? AppColors.textSecondary
                        : AppColors.danger,
                    size: 18,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: _speedValid
                          ? AppColors.disabled
                          : AppColors.danger,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: _speedValid ? AppColors.primary : AppColors.danger,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
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
      ],
    );
  }
}

// ── Buttons ───────────────────────────────────────────────────────────────────
// Los tres botones siguen la misma regla: el estado del provider decide si están
// activos. Deshabilitarlos es la primera barrera de seguridad (la de verdad está
// en el provider y en la estación de tierra).

class _ConnectButton extends StatelessWidget {
  final double screenH;
  final DronProvider provider;

  const _ConnectButton({required this.screenH, required this.provider});

  @override
  Widget build(BuildContext context) {
    // Solo se puede conectar si no hay ya una conexión ni un intento en curso
    final bool active = !provider.isLoading && !provider.isConnected;

    return SizedBox(
      width: double.infinity,
      height: screenH * 0.075,
      child: GestureDetector(
        onTap: active ? context.read<DronProvider>().connectDron : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: active ? AppColors.primary : AppColors.disabled,
            borderRadius: BorderRadius.circular(14),
            border: active
                ? Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Mientras conecta, el icono se sustituye por la ruedecita
              if (provider.isLoading && !provider.isConnected)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(
                  provider.isConnected ? Icons.wifi : Icons.wifi_outlined,
                  size: 20,
                  color: active ? Colors.white : AppColors.textSecondary,
                ),
              const SizedBox(width: 10),
              Text(
                provider.isConnected ? 'CONNECTED' : 'CONNECT',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: active ? Colors.white : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Botón que abre la pantalla de vuelo. Es el punto donde se cruzan las dos
// elecciones del usuario (vehículo y modo de control) para decidir el destino.
class _StartFlightButton extends StatelessWidget {
  final double screenH;
  final DronProvider provider;

  const _StartFlightButton({required this.screenH, required this.provider});

  @override
  Widget build(BuildContext context) {
    // Hace falta estar conectado Y que altitud y velocidad sean válidas
    final bool active =
        !provider.isLoading &&
        provider.isConnected &&
        provider.isConfigValid;

    // El botón se tiñe del color del modo elegido, igual que su píldora
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

    return SizedBox(
      width: double.infinity,
      height: screenH * 0.075,
      child: GestureDetector(
        onTap: active
            ? () {
                // Pantalla completa vía JavaScript: en el navegador la barra de
                // direcciones roba altura y estorba al pilotar.
                requestFullscreenEZ();

                // El Tello manda sobre el modo de control: tenga lo que tenga
                // seleccionado, va siempre a su pantalla dedicada.
                if (provider.droneConnectionMode == DroneConnectionMode.tello) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TelloFlightScreen(),
                    ),
                  );
                  return;
                }
                // Para ArduPilot y SITL, el modo de control elige la pantalla
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: active ? modeColor : AppColors.disabled,
            borderRadius: BorderRadius.circular(14),
            border: active
                ? Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                modeIcon,
                size: 20,
                color: active ? Colors.white : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                'START FLIGHT',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: active ? Colors.white : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisconnectButton extends StatelessWidget {
  final double screenH;
  final DronProvider provider;

  const _DisconnectButton({required this.screenH, required this.provider});

  @override
  Widget build(BuildContext context) {
    // Aquí basta con estar conectado: desde esta pantalla el dron aún no vuela.
    // El bloqueo de "no desconectar en vuelo" está en las pantallas de vuelo.
    final bool enabled = !provider.isLoading && provider.isConnected;

    return SizedBox(
      width: double.infinity,
      height: screenH * 0.065,
      child: GestureDetector(
        onTap: enabled ? context.read<DronProvider>().disconnectDron : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.danger.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: enabled ? AppColors.danger : AppColors.disabled,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.link_off,
                size: 18,
                color: enabled ? AppColors.danger : AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                'DISCONNECT',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: enabled ? AppColors.danger : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Help sheet ────────────────────────────────────────────────────────────────
// Panel deslizante con las instrucciones de uso (el "?" de la barra superior).
// Es solo texto: no toca el provider ni el dron.

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
                  'Camera on: 📷 capture photo · ⏺ record video · 🔄 switch camera',
                ),
                _HelpItem(
                  Icons.zoom_in,
                  'Zoom bar (x1-x5) — available in camera view only',
                ),
                _HelpItem(
                  Icons.search,
                  'YOLO detection — All objects / Persons only / Off (camera view)',
                ),
                _HelpItem(
                  Icons.check_circle,
                  'Flow: CONNECT - ARM - TAKEOFF - fly - LAND or RTL - DISCONNECT',
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
                  'Dead zone ±5-15° (fwd) / ±10° (lateral) ignored',
                ),
                _HelpItem(Icons.info_outline, 'Not available for Tello'),
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
                  'First tap 🎤 — grants microphone permission in the browser',
                ),
                _HelpItem(Icons.mic, 'Hold 🎤 - speak - release - executes'),
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
            const SizedBox(height: 16),
            const _HelpSection(
              icon: Icons.flight,
              title: 'Tello (DJI)',
              color: Colors.lightBlue,
              items: [
                _HelpItem(
                  Icons.wifi,
                  'Connect your device to the Tello Wi-Fi before launching the app',
                ),
                _HelpItem(
                  Icons.sports_esports,
                  'Dual joystick — left: Throttle/Yaw · right: Pitch/Roll',
                ),
                _HelpItem(
                  Icons.flight_takeoff,
                  'TAKEOFF — takes off automatically (~50 cm), no ARM step required',
                ),
                _HelpItem(
                  Icons.flight_land,
                  'LAND — smooth descent and motor stop',
                ),
                _HelpItem(
                  Icons.videocam,
                  'Camera on: 📷 capture photo · ⏺ record video',
                ),
                _HelpItem(
                  Icons.tune,
                  'MODES — opens the Flip, Follow and Orbit panel',
                ),
                _HelpItem(
                  Icons.flip_camera_android,
                  'Flip: tap a direction arrow while flying to execute the flip',
                ),
                _HelpItem(
                  Icons.directions_run,
                  'Follow: activates person-tracking mode (tap STOP to deactivate)',
                ),
                _HelpItem(
                  Icons.rotate_right,
                  'Orbit: orbits around a person — adjust radius with slider (30-200 cm)',
                ),
                _HelpItem(
                  Icons.warning_amber,
                  'Voice and IMU modes are not available for Tello',
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _HelpSection(
              icon: Icons.edit_location_alt_outlined,
              title: 'Flight Planner',
              color: AppColors.primary,
              items: [
                _HelpItem(
                  Icons.map,
                  'Tap the map to add waypoints — numbered in insertion order',
                ),
                _HelpItem(
                  Icons.touch_app,
                  'Tap a waypoint on the map or list to edit its altitude and action',
                ),
                _HelpItem(
                  Icons.drag_handle,
                  'Drag the ≡ handle in the list to reorder waypoints',
                ),
                _HelpItem(
                  Icons.bolt,
                  'Actions per waypoint: None · Hover · Photo · Record · RTL · Land',
                ),
                _HelpItem(
                  Icons.save_outlined,
                  'Save plan locally with 💾 — persists across sessions',
                ),
                _HelpItem(
                  Icons.upload,
                  'UPLOAD — sends the mission to the drone (active connection required)',
                ),
                _HelpItem(
                  Icons.play_arrow,
                  'START — begins autonomous mission once uploaded to the drone',
                ),
                _HelpItem(
                  Icons.download_outlined,
                  'Download plan as a .waypoints file compatible with Mission Planner',
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _HelpSection(
              icon: Icons.history,
              title: 'Flight Log',
              color: AppColors.primary,
              items: [
                _HelpItem(
                  Icons.auto_graph,
                  'Every completed or interrupted flight is recorded automatically',
                ),
                _HelpItem(
                  Icons.map_outlined,
                  'Tap a session to view its trail on an interactive map with a playback slider',
                ),
                _HelpItem(
                  Icons.speed,
                  'Stats: duration · distance · max altitude · altitude gain · max speed · min battery',
                ),
                _HelpItem(
                  Icons.download,
                  'Download telemetry data as a CSV file',
                ),
                _HelpItem(
                  Icons.delete_sweep,
                  'Delete sessions individually or clear all at once',
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
