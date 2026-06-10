import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../provider.dart';
import '../core/styles.dart';
import '../core/web_speech.dart';
import '../core/js_bridges.dart';
import '../core/telemetry_widgets.dart';

// Estado del botón PTT (push-to-talk):
// idle - esperando pulsación, listening - micrófono activo.
enum _ListenState { idle, listening }

// Mapa satélite con overlay de reconocimiento de voz via Web Speech API.
// El operador mantiene pulsado el botón PTT, dicta un comando y lo suelta.
class VoiceFlightScreen extends StatefulWidget {
  const VoiceFlightScreen({super.key});

  @override
  State<VoiceFlightScreen> createState() => _VoiceFlightScreenState();
}

// Pantalla principal de vuelo con control por voz. Usa Web Speech API para reconocimiento
class _VoiceFlightScreenState extends State<VoiceFlightScreen> {
  final WebSpeech _speech = WebSpeech();
  bool _isAvailable = false;
  bool _initAttempted = false;
  bool _permissionGranted =
      false; // true tras aceptar el permiso de micrófono en el navegador
  _ListenState _listenState = _ListenState.idle;

  String _rawText = ''; // texto crudo reconocido en tiempo real
  String _lastCommand = ''; // nombre del último comando ejecutado
  IconData _lastIcon = Icons.mic_none;
  Color _lastColor = AppColors.textSecondary;

  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _stopMove(); // neutraliza ejes por si el usuario sale mientras mueve
    _speech.stopListening();
    _mapController.dispose();
    exitFullscreenEZ();
    super.dispose();
  }

  // Inicializa WebSpeech la primera vez que el usuario toca el micrófono.
  // Registra los tres callbacks (resultado, fin, error) y comprueba disponibilidad.
  Future<bool> _ensureSpeechInit() async {
    if (_initAttempted) return _isAvailable;
    _initAttempted = true;

    final available = await _speech.initialize();

    // Actualiza el texto parcial en pantalla con cada resultado intermedio
    _speech.onResult = (text) {
      if (mounted) setState(() => _rawText = text);
    };

    _speech.onEnd = () {
      // La primera vez que onEnd dispara, el permiso ya fue concedido
      if (!_permissionGranted && mounted) {
        setState(() => _permissionGranted = true);
      }
      // Si estábamos escuchando, procesamos el texto al soltar el botón
      if (_listenState == _ListenState.listening && mounted) {
        setState(() => _listenState = _ListenState.idle);
        if (_rawText.isNotEmpty) _processText(_rawText.toLowerCase());
      }
    };

    _speech.onError = (error) {
      debugPrint('WebSpeech error: $error');
      // 'not-allowed' = usuario denegó el permiso; cualquier otro error
      if (error != 'not-allowed' && !_permissionGranted && mounted) {
        setState(() => _permissionGranted = true);
      }
    };

    if (mounted) setState(() => _isAvailable = available);
    return available;
  }

  // Primer tap en el micrófono: lanza inicialización y pide permiso al navegador.
  void _onMicTap() async {
    final available = await _ensureSpeechInit();
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mic not available — Accept the request'),
            backgroundColor: AppColors.danger,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    _speech.startListening(localeId: 'es-ES');
  }

  // Long press START: activa la escucha (modo push-to-talk).
  void _onMicPressStart() async {
    setState(() {
      _listenState = _ListenState.listening;
      _rawText = '';
    });
    _speech.startListening(localeId: 'es-ES');
  }

  // Long press END: para la escucha y procesa el texto reconocido.
  void _onMicPressEnd() {
    _speech.stopListening();
    setState(() => _listenState = _ListenState.idle);
    if (_rawText.isNotEmpty) _processText(_rawText.toLowerCase());
  }

  // Valida y ejecuta el texto reconocido.
  // Si no contiene ninguna palabra clave, muestra "Comando no reconocido".
  void _processText(String text) {
    if (!_hasValidCommand(text)) {
      _setCommand(
        'Command not recognised',
        Icons.help_outline,
        AppColors.disabled,
      );
      return;
    }
    _identifyAndExecute(text);
  }

  // Comprueba si el texto contiene al menos una palabra clave válida.
  bool _hasValidCommand(String text) {
    return text.contains('armar') ||
        text.contains('despegar') ||
        text.contains('adelante') ||
        text.contains('atrás') ||
        text.contains('atras') ||
        text.contains('derecha') ||
        text.contains('izquierda') ||
        text.contains('subir') ||
        text.contains('bajar') ||
        text.contains('para') ||
        text.contains('stop') ||
        text.contains('aterrizar') ||
        text.contains('volver a despegue') ||
        text.contains('volver al despegue');
  }

  // Aplica movimiento continuo actualizando los ejes del joystick en el provider.
  // El timer periódico del provider los envía a Python via WebRTC a 20 Hz.
  void _startContinuousMove({
    double lx = 0.0,
    double ly = 0.0,
    double rx = 0.0,
    double ry = 0.0,
  }) {
    context.read<DronProvider>().updateJoystick(lx: lx, ly: ly, rx: rx, ry: ry);
  }

  void _stopMove() {
    context.read<DronProvider>().updateJoystick(lx: 0, ly: 0, rx: 0, ry: 0);
  }

  // Mapea palabras clave a acciones concretas del provider o movimientos de joystick.
  void _identifyAndExecute(String text) {
    final provider = context.read<DronProvider>();

    // Lista de comandos
    if (text.contains('armar')) {
      _setCommand('ARMAR', Icons.build, AppColors.warning);
      provider.armDron();
    } else if (text.contains('despegar')) {
      _setCommand('DESPEGAR', Icons.flight_takeoff, AppColors.primary);
      provider.takeOff();
    } else if (text.contains('adelante')) {
      _setCommand('MOVER ADELANTE', Icons.arrow_upward, Colors.cyan);
      _startContinuousMove(ry: -1.0);
    } else if (text.contains('atrás') || text.contains('atras')) {
      _setCommand('MOVER ATRÁS', Icons.arrow_downward, Colors.cyan);
      _startContinuousMove(ry: 1.0);
    } else if (text.contains('derecha')) {
      _setCommand('MOVER DERECHA', Icons.arrow_forward, Colors.lightBlue);
      _startContinuousMove(rx: 1.0);
    } else if (text.contains('izquierda')) {
      _setCommand('MOVER IZQUIERDA', Icons.arrow_back, Colors.lightBlue);
      _startContinuousMove(rx: -1.0);
    } else if (text.contains('subir')) {
      _setCommand('SUBIR', Icons.keyboard_double_arrow_up, Colors.lightGreen);
      _startContinuousMove(ly: 0.35);
    } else if (text.contains('bajar')) {
      _setCommand('BAJAR', Icons.keyboard_double_arrow_down, Colors.amber);
      _startContinuousMove(ly: -0.35);
    } else if (text.contains('para') || text.contains('stop')) {
      _setCommand('PARAR', Icons.stop_circle, AppColors.danger);
      _stopMove();
    } else if (text.contains('aterrizar')) {
      _setCommand('ATERRIZAR', Icons.flight_land, AppColors.danger);
      provider.land();
    } else if (text.contains('volver a despegue') ||
        text.contains('volver al despegue')) {
      _setCommand('VOLVER A DESPEGUE', Icons.home, Colors.blue);
      provider.rtl();
    }
  }

  // Actualiza el panel de último comando con nombre, icono y color.
  void _setCommand(String command, IconData icon, Color color) {
    if (mounted) {
      setState(() {
        _lastCommand = command;
        _lastIcon = icon;
        _lastColor = color;
      });
    }
  }

  // Calcula el punto final del vector de velocidad para dibujarlo en el mapa.
  LatLng _calcVelocityEndPoint(double lat, double lon, double vx, double vy) {
    final speed = sqrt(vx * vx + vy * vy);
    if (speed < 0.5) return LatLng(lat, lon);
    const scale = 6.0;
    final dlat = vx * scale / 111320;
    final dlon = vy * scale / (111320 * cos(lat * pi / 180));
    return LatLng((lat + dlat/50), (lon + dlon/50));
  }

  // Recentra el mapa sobre el dron
  void _centerOnDrone(double lat, double lon) {
    if (lat != 0.0 && lon != 0.0) {
      try {
        _mapController.move(LatLng(lat, lon), _mapController.camera.zoom);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    final bool isListening = _listenState == _ListenState.listening;
    final bool hasCommand =
        _lastCommand.isNotEmpty && _lastCommand != 'Command not recognised';

    //Posición inicial del mapa: dron si tiene GPS, campus EETAC si no
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
            // --------- BARRA SUPERIOR: CHIPS DE ESTADO + BATERÍA + MENSAJE ---
            StatusBanner(provider: provider),
            // --------- BARRA DE TELEMETRÍA ----------------------------------
            CompactTelemetryRow(provider: provider),

            // ---------- ZONA CENTRAL ---------------------------
            Expanded(
              child: Stack(
                children: [
                  // -------- MAPA SATELITAL
                  Padding(
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
                        child: FlutterMap(
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
                            // Vector de velocidad
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
                                        provider.currentVx,
                                        provider.currentVy,
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
                      ),
                    ),
                  ),

                  // ----------- Botón DISCONNECT
                  // Deshabilitado si el dron está armado o volando
                  Positioned(
                    top: screenH * 0.02,
                    right: screenW * 0.03,
                    child: GestureDetector(
                      onTap:
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
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: (provider.isLoading ||
                                  !provider.isConnected ||
                                  provider.isArmed ||
                                  provider.isFlying)
                              ? Colors.transparent
                              : AppColors.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (provider.isLoading ||
                                    !provider.isConnected ||
                                    provider.isArmed ||
                                    provider.isFlying)
                                ? AppColors.disabled
                                : AppColors.danger,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.link_off,
                              size: 14,
                              color: (provider.isLoading ||
                                      !provider.isConnected ||
                                      provider.isArmed ||
                                      provider.isFlying)
                                  ? AppColors.textSecondary
                                  : AppColors.danger,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'DISC',
                              style: TextStyle(
                                color: (provider.isLoading ||
                                        !provider.isConnected ||
                                        provider.isArmed ||
                                        provider.isFlying)
                                    ? AppColors.textSecondary
                                    : AppColors.danger,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // --------- Overlay de voz
                  Positioned(
                    bottom: screenH * 0.025,
                    left: screenW * 0.04,
                    right: screenW * 0.04,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Panel de estado de reconocimiento (idle / listening / detected)
                        Expanded(
                          child: _VoiceStatePanel(
                            isListening: isListening,
                            permissionGranted: _permissionGranted,
                            hasCommand: hasCommand,
                            rawText: _rawText,
                            lastCommand: _lastCommand,
                            lastIcon: _lastIcon,
                            lastColor: _lastColor,
                          ),
                        ),
                        SizedBox(width: screenW * 0.03),

                        // ----- Botón PTT
                        // Tap simple  - activa permiso de micrófono (primera vez)
                        // Long press  - graba mientras se mantiene pulsado
                        // Color: gris=sin permiso, verde=listo, rojo=escuchando
                        SizedBox(
                          width: 84,
                          height: 84,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Anillo de pulso animado mientras escucha
                              if (isListening)
                                const _PulseRing(
                                  color: AppColors.danger,
                                  maxSize: 84,
                                ),
                              GestureDetector(
                                onTap: _permissionGranted ? null : _onMicTap,
                                onLongPressStart: _permissionGranted
                                    ? (_) => _onMicPressStart()
                                    : null,
                                onLongPressEnd: _permissionGranted
                                    ? (_) => _onMicPressEnd()
                                    : null,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: isListening ? 68 : 56, // crece al escuchar
                                  height: isListening ? 68 : 56,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isListening
                                        ? AppColors.danger
                                        : _permissionGranted
                                        ? AppColors.primary
                                        : AppColors.disabled,
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.18),
                                      width: 1.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: (isListening
                                                ? AppColors.danger
                                                : _permissionGranted
                                                ? AppColors.primary
                                                : Colors.black)
                                            .withValues(alpha: 0.4),
                                        blurRadius: isListening ? 18 : 8,
                                        spreadRadius: isListening ? 2 : 0,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    isListening
                                        ? Icons.mic
                                        : _permissionGranted
                                        ? Icons.mic_none
                                        : Icons.mic_off,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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

// ── Panel de estado de reconocimiento de voz ─────────────────────────────────
// Tres estados visuales: idle (esperando), listening (escuchando, transcripción
// en vivo destacada) y detected (comando reconocido con su color/icono).
class _VoiceStatePanel extends StatelessWidget {
  final bool isListening;
  final bool permissionGranted;
  final bool hasCommand;
  final String rawText;
  final String lastCommand;
  final IconData lastIcon;
  final Color lastColor;

  const _VoiceStatePanel({
    required this.isListening,
    required this.permissionGranted,
    required this.hasCommand,
    required this.rawText,
    required this.lastCommand,
    required this.lastIcon,
    required this.lastColor,
  });

  @override
  Widget build(BuildContext context) {
    // Color de acento según el estado activo
    final Color accent = isListening
        ? AppColors.danger
        : hasCommand
            ? lastColor
            : AppColors.textSecondary;

    final String headerLabel = isListening ? 'LISTENING' : 'VOICE COMMAND';
    final IconData headerIcon = isListening ? Icons.graphic_eq : Icons.mic;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: (isListening || hasCommand) ? accent : AppColors.border,
          width: (isListening || hasCommand) ? 1.5 : 1.0,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: isListening
            ? [
                BoxShadow(
                  color: AppColors.danger.withValues(alpha: 0.25),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header de sección — estilo SetupScreen
          Row(
            children: [
              Icon(headerIcon, size: 11, color: accent),
              const SizedBox(width: 5),
              Text(
                headerLabel,
                style: TextStyle(
                  color: accent,
                  fontSize: 9,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isListening) ...[
                const SizedBox(width: 6),
                const _ListeningDots(color: AppColors.danger),
              ],
            ],
          ),
          const SizedBox(height: 7),
          // Cuerpo del panel según estado
          if (isListening)
            // Transcripción en vivo destacada
            Text(
              rawText.isEmpty ? 'Escuchando…' : rawText,
              style: TextStyle(
                color: rawText.isEmpty
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                fontStyle: rawText.isEmpty ? FontStyle.italic : FontStyle.normal,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          else if (hasCommand)
            // Último comando reconocido
            Row(
              children: [
                Icon(lastIcon, color: lastColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lastCommand,
                    style: TextStyle(
                      color: lastColor,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else
            // Estado idle — instrucciones
            Row(
              children: [
                Icon(
                  permissionGranted ? Icons.touch_app : Icons.mic_off,
                  color: AppColors.textSecondary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    permissionGranted
                        ? 'Mantén pulsado 🎤 y di un comando'
                        : 'Pulsa 🎤 para activar el micrófono',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// Tres puntos que parpadean en secuencia — indicador "escuchando".
class _ListeningDots extends StatefulWidget {
  final Color color;
  const _ListeningDots({required this.color});

  @override
  State<_ListeningDots> createState() => _ListeningDotsState();
}

class _ListeningDotsState extends State<_ListeningDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Cada punto desfasado 1/3 de ciclo
            final phase = (_ctrl.value - i / 3) % 1.0;
            final opacity = (0.3 + 0.7 * (1 - (phase * 2 - 1).abs())).clamp(0.3, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// Anillo concéntrico que se expande y desvanece en bucle alrededor del micrófono.
class _PulseRing extends StatefulWidget {
  final Color color;
  final double maxSize;
  const _PulseRing({required this.color, required this.maxSize});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        // Dos ondas desfasadas para un pulso continuo
        return Stack(
          alignment: Alignment.center,
          children: List.generate(2, (i) {
            final t = (_ctrl.value + i * 0.5) % 1.0;
            final size = widget.maxSize * (0.65 + 0.35 * t);
            final opacity = (1.0 - t).clamp(0.0, 1.0) * 0.5;
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.color.withValues(alpha: opacity),
                  width: 2,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
