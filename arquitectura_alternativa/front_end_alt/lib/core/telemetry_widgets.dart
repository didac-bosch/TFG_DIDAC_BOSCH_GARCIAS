import 'package:flutter/material.dart';

import '../provider.dart';
import 'styles.dart';

// Widgets de telemetría y estado del dron, usados en varias pantallas para mostrar información clave de forma compacta y visual.
// Están aquí y no dentro de una pantalla concreta precisamente porque los
// comparten la pantalla clásica, la de voz y la de IMU: así el piloto ve siempre
// la misma información con el mismo aspecto, sea cual sea el modo de control.

// ── Status Banner ─────────────────────────────────────────────────────────────
// Chips de estado (conexión/modo, armado, modo de vuelo, estado de vuelo) +
// indicador de batería + ticker con el mensaje del provider.
class StatusBanner extends StatelessWidget {
  final DronProvider provider;
  const StatusBanner({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final Color connColor = provider.isLoading
        ? AppColors.warning
        : provider.isConnected
            ? AppColors.primary
            : AppColors.disabled;

    final String modeLabel = switch (provider.droneConnectionMode) {
      DroneConnectionMode.ardupilot => 'ARDUPILOT',
      DroneConnectionMode.sitl => 'SITL',
      DroneConnectionMode.tello => 'TELLO',
    };

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              // Conexión
              StatusPill(
                color: connColor,
                icon: provider.isLoading
                    ? null
                    : provider.isConnected
                        ? Icons.wifi
                        : Icons.wifi_off,
                loading: provider.isLoading && !provider.isConnected,
                label: modeLabel,
              ),

              // Armed / Disarmed
              StatusPill(
                color: provider.isArmed ? AppColors.danger : AppColors.disabled,
                icon: provider.isArmed
                    ? Icons.warning_amber_rounded
                    : Icons.lock_outline,
                label: provider.isArmed ? 'ARMED' : 'DISARMED',
              ),

              // Modo de vuelo
              if (provider.isConnected)
                StatusPill(
                  color: provider.isFlying ? AppColors.primary : AppColors.disabled,
                  icon: Icons.airplanemode_active,
                  label: provider.currentMode.isNotEmpty &&
                          provider.currentMode != 'Unknown'
                      ? provider.currentMode
                      : 'UNKNOWN',
                ),

              // Estado de vuelo
              if (provider.isFlying)
                StatusPill(
                  color: AppColors.primary,
                  icon: Icons.flight,
                  label: 'IN FLIGHT',
                  pulse: true,
                )
              else if (provider.isConnected)
                StatusPill(
                  color: AppColors.disabled,
                  icon: Icons.flight_land,
                  label: 'ON GROUND',
                ),

              // Batería
              BatteryGauge(bat: provider.currentBat),
            ],
          ),
          // Mensaje de sistema 
          if (provider.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  provider.message,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Chip de estado con indicador 
class StatusPill extends StatefulWidget {
  final Color color;
  final IconData? icon;
  final String label;
  final bool loading;
  final bool pulse;

  const StatusPill({
    super.key,
    required this.color,
    required this.label,
    this.icon,
    this.loading = false,
    this.pulse = false,
  });

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusPill old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.pulse && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget dot = widget.loading
        ? SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: widget.color,
            ),
          )
        : widget.pulse
            ? FadeTransition(
                opacity: _opacity,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              )
            : Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: widget.color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          if (widget.icon != null) ...[
            const SizedBox(width: 4),
            Icon(widget.icon, color: widget.color, size: 11),
          ],
          const SizedBox(width: 4),
          Text(
            widget.label,
            style: TextStyle(
              color: widget.color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Batería ─────────────────────────────────────────────────────────────
// Indicador de batería con forma de pila. Es información crítica, así que se
// codifica por color además de por número: tiene que leerse de un vistazo, sin
// llegar a mirar la cifra.

class BatteryGauge extends StatelessWidget {
  final double bat;
  const BatteryGauge({super.key, required this.bat});

  // Verde por encima del 50 %, naranja entre 20 y 50, rojo por debajo de 20
  Color get _color {
    if (bat > 50) return AppColors.primary;
    if (bat > 20) return AppColors.warning;
    return AppColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    // El porcentaje se reparte en 5 segmentos (uno por cada 20 %)
    final int filled = (bat / 100 * 5).round().clamp(0, 5);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Segmentos
        Row(
          children: List.generate(5, (i) {
            return Container(
              width: 7,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: i < filled ? _color : AppColors.disabled,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
        const SizedBox(width: 2),
        // Tapa de la batería
        Container(
          width: 3,
          height: 7,
          decoration: BoxDecoration(
            color: AppColors.disabled,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(2)),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${bat.toInt()}%',
          style: TextStyle(
            color: _color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ── Fila telemetría compacta ─────────────────────────────────────────────────────

class CompactTelemetryRow extends StatelessWidget {
  final DronProvider provider;
  const CompactTelemetryRow({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          Expanded(child: MiniTelem(Icons.height, 'ALT', '${provider.currentAlt.toStringAsFixed(2)}m')),
          Expanded(child: MiniTelem(Icons.speed, 'GS', '${provider.currentSpeed.toStringAsFixed(2)}m/s')),
          Expanded(child: MiniTelem(Icons.explore, 'HDG', '${provider.currentHeading.toInt()}°')),
          Expanded(child: MiniTelem(Icons.location_on, 'LAT', provider.currentLat.toStringAsFixed(6))),
          Expanded(child: MiniTelem(Icons.location_searching, 'LON', provider.currentLon.toStringAsFixed(4))),
          Expanded(child: MiniTelem(Icons.info_outline, 'STATE', provider.currentState)),
        ],
      ),
    );
  }
}

class MiniTelem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const MiniTelem(this.icon, this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary, size: 9),
            const SizedBox(width: 2),
            Text(label, style: TextStyles.instrumentLabel.copyWith(fontSize: 8)),
          ],
        ),
        Text(
          value,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
