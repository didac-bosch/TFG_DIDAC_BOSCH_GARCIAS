import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'flight_screen.dart';
import 'voice_flight_screen.dart';
import 'imu_flight_screen.dart';
import '../core/fullscreen.dart';

// Pantalla de configuración inicial.
// Permite conectar el dron, ajustar altitud/velocidad,
// seleccionar el modo de control y lanzar el vuelo.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('EZDRONE', style: TextStyles.title),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
      ),
      body: SafeArea(
        // Layout adaptativo: columna en portrait, dos columnas en landscape
        child: OrientationBuilder(
          builder: (context, orientation) {
            return orientation == Orientation.portrait
                ? _buildPortrait(context, provider, screenW, screenH)
                : _buildLandscape(context, provider, screenW, screenH);
          },
        ),
      ),
    );
  }

  // Layout portrait: elementos apilados verticalmente en scroll
  Widget _buildPortrait(
    BuildContext context,
    DronProvider provider,
    double screenW,
    double screenH,
  ) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(vertical: screenH * 0.02),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: screenH * 0.03),
          FaIcon(
            FontAwesomeIcons.helicopterSymbol,
            size: screenW * 0.2,
            // Verde si conectado, gris si no
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
          _ConfigFields(screenW: screenW, provider: provider),
          SizedBox(height: screenH * 0.03),
          _ModeSelector(screenW: screenW, provider: provider),
          SizedBox(height: screenH * 0.04),
          _ConnectButton(screenW: screenW, screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.015),
          _StartFlightButton(screenW: screenW, screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.015),
          _DisconnectButton(screenW: screenW, screenH: screenH, provider: provider),
          SizedBox(height: screenH * 0.02),
        ],
      ),
    );
  }

  // Layout landscape: icono + estado + modo a la izquierda,
  // config + botones a la derecha
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
                SizedBox(height: screenH * 0.025),
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
                _ConfigFields(screenW: screenW * 0.5, provider: provider),
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


// Caja de texto que muestra el mensaje de estado del provider
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

//Campos configuración, se muestran en rojo si está mal o fuera del rango
class _ConfigFields extends StatelessWidget {
  final double screenW;
  final DronProvider provider;

  const _ConfigFields({required this.screenW, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: screenW * 0.05),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SizedBox(
            width: screenW * 0.35,
            child: TextFormField(
              initialValue: provider.takeoffAltitude.toString(),
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Alt (m)',
                helperText: '2.0 - 50.0',
                helperStyle: TextStyle(
                  color: provider.isConfigValid
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
                    color: provider.isConfigValid
                        ? AppColors.primary
                        : AppColors.danger,
                  ),
                ),
              ),
              onChanged: (v) => context.read<DronProvider>().setAltitude(v),
            ),
          ),
          SizedBox(
            width: screenW * 0.35,
            child: TextFormField(
              initialValue: provider.flightSpeed.toString(),
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Speed (m/s)',
                helperText: '1.0 - 15.0',
                helperStyle: TextStyle(
                  color: provider.isConfigValid
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
                    color: provider.isConfigValid
                        ? AppColors.primary
                        : AppColors.danger,
                  ),
                ),
              ),
              onChanged: (v) => context.read<DronProvider>().setSpeed(v),
            ),
          ),
        ],
      ),
    );
  }
}



// Selector de modo de control: Classic (joystick),
// Voice (comandos de voz) o IMU (inclinación del dispositivo).
// Cada chip se resalta con su color propio cuando está seleccionado.
class _ModeSelector extends StatelessWidget {
  final double screenW;
  final DronProvider provider;

  const _ModeSelector({required this.screenW, required this.provider});

  @override
  Widget build(BuildContext context) {
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
                onTap: () => context
                    .read<DronProvider>()
                    .setControlMode(ControlMode.classic),
              ),
              _ModeChip(
                label: 'Voice',
                icon: Icons.mic,
                color: Colors.teal,
                mode: ControlMode.voice,
                selected: provider.selectedMode,
                onTap: () => context
                    .read<DronProvider>()
                    .setControlMode(ControlMode.voice),
              ),
              _ModeChip(
                label: 'IMU',
                icon: Icons.sensors,
                color: Colors.deepPurple,
                mode: ControlMode.imu,
                selected: provider.selectedMode,
                onTap: () => context
                    .read<DronProvider>()
                    .setControlMode(ControlMode.imu),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Muestra borde y color de acento cuando está seleccionado.
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


// ---------BOTONES-----------------------

// Inicia la conexión MQTT + WebRTC con la Ground Station.
// Deshabilitado mientras carga o si ya está conectado.
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

// Navega a la pantalla de vuelo correspondiente al modo seleccionado.
// Solicita pantalla completa al navegador antes de navegar.
// Solo habilitado si está conectado y la configuración es válida.
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
        !provider.isLoading && provider.isConnected && provider.isConfigValid;

    // Color e icono cambian según el modo de control activo
    final Color modeColor = switch (provider.selectedMode) {
      ControlMode.classic => AppColors.primary,
      ControlMode.voice   => Colors.teal,
      ControlMode.imu     => Colors.deepPurple,
    };

    final IconData modeIcon = switch (provider.selectedMode) {
      ControlMode.classic => Icons.flight_takeoff,
      ControlMode.voice   => Icons.mic,
      ControlMode.imu     => Icons.sensors,
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
                  requestFullscreenEZ(); // pantalla completa vía JS Interop
                  switch (provider.selectedMode) {
                    case ControlMode.classic:
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const FlightScreen()));
                    case ControlMode.voice:
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const VoiceFlightScreen()));
                    case ControlMode.imu:
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const ImuFlightScreen()));
                  }
                }
              : null,
        ),
      ),
    );
  }
}

// Desconecta el dron y limpia todo el estado del provider.
// Siempre visible; deshabilitado si no hay conexión activa o está cargando.
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