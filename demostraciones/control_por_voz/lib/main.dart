import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

// ============================================================
// DEMO: CONTROL DE DRON POR VOZ CON WAKE WORD
// ============================================================
//
// LIBRERÍA:
//   - speech_to_text: ^6.6.2 → puente con el motor nativo
//       · iOS/macOS → Siri/Apple
//       · Android   → Google
//
// PERMISOS NECESARIOS:
//   iOS    → ios/Runner/Info.plist:
//              NSMicrophoneUsageDescription
//              NSSpeechRecognitionUsageDescription
//   macOS  → macos/Runner/Info.plist: (igual que iOS)
//            macos/Runner/DebugProfile.entitlements y Release.entitlements:
//              com.apple.security.device.microphone
//              com.apple.security.device.audio-input
//   Android → android/app/src/main/AndroidManifest.xml:
//              RECORD_AUDIO, INTERNET, BLUETOOTH, BLUETOOTH_ADMIN
//              + <queries> RecognitionService si targetSdk >= 30
//
// FUNCIONAMIENTO:
//   1. Pulsar botón → escucha activa con timer de 10s
//   2. Cualquier voz detectada → resetea el timer de 10s
//   3. Silencio de 10s sin comandos → se apaga automáticamente
//   4. "dron" detectado → espera comando (timer sigue activo)
//   5. "dron" + comando detectado → ejecuta al instante,
//      se queda encendido indefinidamente hasta stop manual
//
// NOTA: detección instantánea via resultados parciales,
//       sin esperar a que el motor pare.
//
// ESTADOS:
//   idle            → apagado
//   waitingWakeWord → escuchando, timer activo, esperando "dron"
//   waitingCommand  → "dron" detectado, esperando comando
//   commandLocked   → comando ejecutado, encendido permanente
//
// COMANDOS RECONOCIDOS:
//   "armar"            → ARMAR
//   "despegar"         → DESPEGAR
//   "subir"            → SUBIR
//   "bajar"            → BAJAR
//   "mover derecha"    → MOVER DERECHA
//   "mover izquierda"  → MOVER IZQUIERDA
//   "mover adelante"   → MOVER ADELANTE
//   "mover atrás"      → MOVER ATRÁS
//   "aterrizar"        → ATERRIZAR
//   "volver a despegue"→ VOLVER A DESPEGUE
// ============================================================

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Control por Voz',
      theme: ThemeData.dark(),
      home: const VoiceControlScreen(),
    );
  }
}

// Máquina de estados del sistema de escucha. Define en qué fase está la app en cada momento:
//   idle            → apagado, no escucha nada
//   waitingWakeWord → escuchando, esperando que el usuario diga "dron"
//   waitingCommand  → "dron" detectado, esperando el comando concreto
//   commandLocked   → comando ejecutado, sigue escuchando indefinidamente
enum ListenState { idle, waitingWakeWord, waitingCommand, commandLocked }

class VoiceControlScreen extends StatefulWidget {
  const VoiceControlScreen({super.key});
  @override
  State<VoiceControlScreen> createState() => _VoiceControlScreenState();
}

class _VoiceControlScreenState extends State<VoiceControlScreen> {
  final SpeechToText _speech = SpeechToText();

  bool _isAvailable = false;                    // Si el dispositivo soporta reconocimiento de voz
  ListenState _listenState = ListenState.idle;  // Estado actual de la máquina de estados
  String _rawText = '';                         // Texto que va transcribiendo el motor en tiempo real
  String _command = '';                         // Nombre del último comando identificado
  IconData _commandIcon = Icons.mic_none;       // Icono asociado al comando actual
  Color _commandColor = Colors.white;           // Color asociado al comando actual

  Timer? _autoOffTimer; //timer para pararse solo si en 10s no se ha dicho nada
  static const _autoOffSeconds = 10;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  @override
  void dispose() {
    _autoOffTimer?.cancel();
    super.dispose();
  }

  Future<void> _initSpeech() async {    //inicia el motor de reconocimiento de voz, si ha habido error reintenta la escucha
    _isAvailable = await _speech.initialize(
      onError: (error) {
        if (_listenState != ListenState.idle) {
          Future.delayed(const Duration(milliseconds: 500), _listenLoop);
        }
      },
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') &&
            _listenState != ListenState.idle) {
          Future.delayed(const Duration(milliseconds: 300), _listenLoop);
        }
      },
    );
    setState(() {});
  }

  void _startAutoOffTimer() { //timer para auto parar
    _autoOffTimer?.cancel();
    _autoOffTimer = Timer(const Duration(seconds: _autoOffSeconds), () {
      _stopEverything();
    });
  }

  void _resetAutoOffTimer() {  //resetear el contador cada vez que se escucha algo
    if (_listenState != ListenState.commandLocked) {
      _startAutoOffTimer();
    }
  }

  void _cancelAutoOffTimer() {  //anular timer si se pulsa manualmente
    _autoOffTimer?.cancel();
    _autoOffTimer = null;
  }

  void _toggleListening() {         //toggle del botón principal, para encender o apagar todo
    if (_listenState != ListenState.idle) {
      _stopEverything();
    } else {
      _startWakeWordMode();
    }
  }

  void _startWakeWordMode() {   //inicio de escucha y espera a la wakeword
    setState(() {
      _listenState = ListenState.waitingWakeWord;
      _rawText = '';
      _command = '';
      _commandIcon = Icons.mic_none;
      _commandColor = Colors.white;
    });
    _startAutoOffTimer();
    _listenLoop();
  }

  void _stopEverything() {    //final de todo
    _cancelAutoOffTimer();
    _speech.stop();
    setState(() {
      _listenState = ListenState.idle;
      _rawText = '';
      _command = '';
      _commandIcon = Icons.mic_none;
      _commandColor = Colors.white;
    });
  }

  void _listenLoop() {      //bucle de escucha
    if (_listenState == ListenState.idle) return;
    _speech.listen(
      onResult: _onResult,
      localeId: 'es_ES',
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 2),
    );
  }

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.toLowerCase();
    setState(() => _rawText = result.recognizedWords);  //mostrar texto cada vez que se detecta algo

    if (text.isEmpty) return;

    // Cualquier voz detectada resetea el timer de silencio
    _resetAutoOffTimer();

    _processTextPartial(text);
  }

  void _processTextPartial(String text) { //según el estado espera una palabra o la otra
    switch (_listenState) {
      case ListenState.waitingWakeWord: //espera a dron (wakeword)
        _handleWakeWordPartial(text);
        break;
      case ListenState.waitingCommand:  //espera dron + comando
        _handleCommandPartial(text);
        break;
      case ListenState.commandLocked: // En commandLocked también escucha por si hay nuevo comando con dron
        _handleWakeWordPartial(text);
        break;
      case ListenState.idle:
        break;
    }
  }

  void _handleWakeWordPartial(String text) {    //lógica de escucha. Si escucha dron se pone en waiting command. Y a la que escucha dron + comando ejecuta el comando
    final hasDron = text.contains('dron') || text.contains('drone');
    if (!hasDron) return;

    final afterDron = text.contains('drone')  //palabra después de dron
        ? text.split('drone').last.trim()
        : text.split('dron').last.trim();

    if (afterDron.isNotEmpty && _hasValidCommand(afterDron)) {
      // "dron armar"  ejecutar al instante y bloquear encendido
      _speech.stop();
      _cancelAutoOffTimer();  //micro escuchando permanentemente hasta que se apaga
      setState(() => _listenState = ListenState.commandLocked);
      _identifyCommand(afterDron);
      Future.delayed(const Duration(milliseconds: 500), _listenLoop); //pausa antes de volver a escuchar para no sobresaturar
    } else if (afterDron.isEmpty) {
      // Solo "dron" pasar a esperar comando
      setState(() {
        _listenState = ListenState.waitingCommand;  //waiting command
        _command = '';
        _commandIcon = Icons.hearing;
        _commandColor = Colors.greenAccent;
      });
    }
  }

  void _handleCommandPartial(String text) { //si solo se ha dicho dron se activa modo waiting
    if (!_hasValidCommand(text)) return;

    // Comando detectado ejecutar al instante y bloquear encendido
    _speech.stop();
    _cancelAutoOffTimer();
    setState(() => _listenState = ListenState.commandLocked);
    _identifyCommand(text);
    Future.delayed(const Duration(milliseconds: 500), _listenLoop);
  }

  bool _hasValidCommand(String text) {  //commandos válidos
    return text.contains('armar') ||
           text.contains('despegar') ||
           text.contains('mover derecha') ||
           text.contains('mover izquierda') ||
           text.contains('mover adelante') ||
           text.contains('mover atrás') ||
           text.contains('mover atras') ||
           text.contains('subir') ||
           text.contains('bajar') ||
           text.contains('aterrizar') ||
           text.contains('volver a despegue') ||
           text.contains('volver al despegue');
  }

  void _identifyCommand(String text) {    //identificadores comandos
    if (text.contains('armar')) {
      _setCommand('ARMAR', Icons.build, Colors.orange);
    } else if (text.contains('despegar')) {
      _setCommand('DESPEGAR', Icons.flight_takeoff, Colors.green);
    } else if (text.contains('mover derecha') || text.contains('mueve derecha')) {
      _setCommand('MOVER DERECHA', Icons.arrow_forward, Colors.lightBlue);
    } else if (text.contains('mover izquierda') || text.contains('mueve izquierda')) {
      _setCommand('MOVER IZQUIERDA', Icons.arrow_back, Colors.lightBlue);
    } else if (text.contains('mover adelante') || text.contains('mueve adelante')) {
      _setCommand('MOVER ADELANTE', Icons.arrow_upward, Colors.cyan);
    } else if (text.contains('mover atrás') || text.contains('mover atras') ||
               text.contains('mueve atrás') || text.contains('mueve atras')) {
      _setCommand('MOVER ATRÁS', Icons.arrow_downward, Colors.cyan);
    } else if (text.contains('subir')) {
      _setCommand('SUBIR', Icons.keyboard_double_arrow_up, Colors.lightGreen);
    } else if (text.contains('bajar')) {
      _setCommand('BAJAR', Icons.keyboard_double_arrow_down, Colors.amber);
    } else if (text.contains('aterrizar')) {
      _setCommand('ATERRIZAR', Icons.flight_land, Colors.deepOrange);
    } else if (text.contains('volver a despegue') || text.contains('volver al despegue')) {
      _setCommand('VOLVER A DESPEGUE', Icons.home, Colors.blue);
    } else {
      _setCommand('No reconocido', Icons.help_outline, Colors.grey);
    }
  }

  void _setCommand(String command, IconData icon, Color color) {  //actualizador de pantalla
    setState(() {
      _command = command;
      _commandIcon = icon;
      _commandColor = color;
    });
  }

  String get _statusText {  //texto que aparece debajo del botón
    switch (_listenState) {
      case ListenState.idle:
        return 'Pulsa para activar';
      case ListenState.waitingWakeWord:
        return 'Di "dron" para activar...';
      case ListenState.waitingCommand:
        return 'Di el comando...';
      case ListenState.commandLocked:
        return 'Activo - di "dron + comando"';
    }
  }

  Color get _buttonColor {  //color según estado
    switch (_listenState) {
      case ListenState.idle:
        return Colors.blue;
      case ListenState.waitingWakeWord:
        return Colors.blueGrey;
      case ListenState.waitingCommand:
        return Colors.red;
      case ListenState.commandLocked:
        return Colors.green;
    }
  }

  bool get _hasCommand =>
      _command.isNotEmpty && _command != 'No reconocido';

  @override
  Widget build(BuildContext context) {
    final bool isActive = _listenState != ListenState.idle;
    final bool waitingCmd =
        _listenState == ListenState.waitingCommand && _command.isEmpty;

    return Scaffold(  //pantalla
      appBar: AppBar(title: const Text('Control por voz')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [

            // Recuadro de comando: muestra el icono y nombre del comando detectado.
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              width: 300,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
              decoration: BoxDecoration(
                color: _hasCommand
                    ? Color.fromRGBO(
                        (_commandColor.r * 0.25).round(),
                        (_commandColor.g * 0.25).round(),
                        (_commandColor.b * 0.25).round(),
                        1.0,
                      )
                    : const Color(0xFF1A1A2E),
                border: Border.all(
                  color: _hasCommand ? _commandColor : Colors.white24,
                  width: _hasCommand ? 2.5 : 1,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  //ICONO
                  Icon(
                    waitingCmd ? Icons.hearing : _commandIcon,
                    size: 64,
                    color: waitingCmd ? Colors.greenAccent : Colors.white,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    waitingCmd
                        ? 'Dron activado'
                        : (_command.isEmpty ? 'En espera...' : _command),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: waitingCmd
                          ? Colors.greenAccent
                          : (_command.isEmpty ? Colors.white38 : Colors.white),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            //texto que se detecta
            Text(
              _rawText.isEmpty ? '' : '"$_rawText"',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),

            const SizedBox(height: 48),

            //botón microfono
            GestureDetector(
              onTap: _isAvailable ? _toggleListening : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: isActive ? 100 : 80,
                height: isActive ? 100 : 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _buttonColor,
                  boxShadow: isActive
                      ? [BoxShadow(
                          color: _buttonColor,
                          blurRadius: 20,
                          spreadRadius: 4,
                        )]
                      : [],
                ),
                child: Icon(
                  isActive ? Icons.mic : Icons.mic_none,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
            const SizedBox(height: 20),

            Text(_statusText, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
