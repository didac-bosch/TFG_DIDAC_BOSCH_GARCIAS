import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================
// DEMO: VÍDEO WEBRTC + YOLO + CAPTURA + GRABACIÓN
// ============================================================
//
// Recibe el vídeo de una cámara por WebRTC y lo muestra en directo, con
// detección de objetos YOLO aplicada en el lado emisor. Además permite
// capturar fotogramas y grabar clips desde el propio navegador.
//
// FUNCIONAMIENTO:
//   1. Stream WebRTC con detección YOLO seleccionable (Todo / Personas / Ninguno).
//   2. Captura de pantalla -> PNG que se descarga en la carpeta Descargas.
//   3. Grabación de vídeo  -> WebM que se descarga en la carpeta Descargas.
//
// CAPTURA Y GRABACIÓN (100 % en el cliente, vía JS Interop):
//   index.html expone captureDroneFrame() y startDroneRecording(); Dart
//   simplemente las llama, sin que Python intervenga.
//
//   NOTA: webrtc_video_sender.py también sabe capturar y grabar en el
//   servidor (PNG/mp4 con comandos {"type":"capture"|"record_start"}), pero
//   este cliente NO usa esa vía: solo manda {"type":"detection_mode"} y hace
//   la captura/grabación en el navegador. Lo server-side queda de referencia.
//
// REQUISITOS:
//   1. index.html debe definir las funciones JS (captureDroneFrame, etc.).
//   2. Arrancar el emisor: python webrtc_video_sender.py
//      (dependencias: torch, opencv-python, aiortc, av, websockets).
//   3. Poner en senderIP la IP del PC que corre ese script (misma red) y en
//      senderPort el mismo puerto que use el emisor.
// ============================================================

// IP del PC que ejecuta webrtc_video_sender.py — CAMBIAR según tu red.
const String senderIP = '192.168.0.84';
const int senderPort  = 9999;

// ── Puentes JS Interop — funciones definidas en index.html ─────────
@JS('captureDroneFrame')
external void _jsCapture(String filename);

@JS('startDroneRecording')
external void _jsStartRecording();

@JS('stopDroneRecording')
external void _jsStopRecording(String filename);

// Los tres modos de detección YOLO que ofrece la demo
enum DetectionMode { all, person, none }

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  // Objetos WebRTC / señalización
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer(); // pinta el stream remoto
  RTCPeerConnection? _peerConnection;                          // conexión WebRTC
  WebSocketChannel? _wsChannel;                                // canal de señalización (SDP)

  // VARIABLES DE ESTADO
  bool   _isConnected      = false;              // true cuando llega el track de vídeo
  String _status            = 'Desconectado';    // texto de estado que se muestra en pantalla
  DetectionMode _mode       = DetectionMode.all; // modo YOLO activo
  bool   _isRecording       = false;             // true mientras se está grabando
  bool   _showCaptureFlash  = false;             // flash blanco al hacer una captura

  // Se llama al crear el widget: prepara el renderer de vídeo
  @override
  void initState() {
    super.initState();
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  // ── ENVÍO DE COMANDOS A PYTHON ─────────────────────────────────
  // Serializa el comando a JSON y lo manda por el WebSocket al emisor.
  void _sendCommand(Map<String, dynamic> cmd) {
    _wsChannel?.sink.add(json.encode(cmd));
  }

  // ── CONEXIÓN ───────────────────────────────────────────────────
  // Crea la PeerConnection, se suscribe al track de vídeo y abre el
  // WebSocket por el que llegará la oferta SDP del emisor.
  Future<void> _connect() async {
    setState(() => _status = 'Conectando...');
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    });

    // Cuando llega el track de vídeo, se enchufa al renderer y se marca conectado
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
          _isConnected = true;
          _status      = '';
        });
      }
    };

    _wsChannel = WebSocketChannel.connect(
      Uri.parse('ws://$senderIP:$senderPort'),
    );

    // El emisor manda una oferta SDP; se procesa cuando llega
    _wsChannel!.stream.listen((message) async {
      final data = json.decode(message);
      if (data['type'] == 'sdp' && data['sdp_type'] == 'offer') {
        await _handleOffer(data);
      }
    });
  }

  // Responde a la oferta SDP del emisor con la answer (handshake WebRTC)
  Future<void> _handleOffer(Map<String, dynamic> data) async {
    setState(() => _status = 'Conectando...');
    final offer = RTCSessionDescription(data['sdp'], data['sdp_type']);
    await _peerConnection!.setRemoteDescription(offer);
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _wsChannel!.sink.add(json.encode({
      'type': 'sdp', 'sdp': answer.sdp, 'sdp_type': answer.type,
    }));
    setState(() => _status = '');
    // Ya conectados: se manda el modo de detección con el que arranca la UI
    _sendDetectionMode(_mode);
  }

  // ── MODO DE DETECCIÓN ──────────────────────────────────────────
  // Traduce el enum a string y lo envía a Python para que ajuste YOLO
  void _sendDetectionMode(DetectionMode mode) {
    final str = switch (mode) {
      DetectionMode.all    => 'all',
      DetectionMode.person => 'person',
      DetectionMode.none   => 'none',
    };
    _sendCommand({'type': 'detection_mode', 'mode': str});
  }

  // ── CAPTURA DE FRAME (JS Interop) ──────────────────────────────
  // Pide al navegador que guarde el fotograma actual como PNG
  void _capture() {
    if (!_isConnected) return;
    final ts = DateTime.now().millisecondsSinceEpoch; // nombre único por timestamp
    _jsCapture('drone_capture_$ts.png');
    // Flash blanco de 200 ms como confirmación visual
    setState(() => _showCaptureFlash = true);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _showCaptureFlash = false);
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Captura guardada en Descargas'),
      duration: Duration(seconds: 2),
      backgroundColor: Colors.green,
    ));
  }

  // ── GRABACIÓN DE VÍDEO (JS Interop) ───────────────────────────
  // Actúa como interruptor: arranca o para la grabación en el navegador
  void _toggleRecording() {
    if (!_isConnected) return;
    if (_isRecording) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _jsStopRecording('drone_video_$ts.webm');
      setState(() => _isRecording = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Vídeo guardado en Descargas'),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.blue,
      ));
    } else {
      _jsStartRecording();
      setState(() => _isRecording = true);
    }
  }

  // ── DESCONEXIÓN ────────────────────────────────────────────────
  // Cierra WebRTC y WebSocket y deja el estado como al principio
  Future<void> _disconnect() async {
    if (_isRecording) {
      // si estaba grabando, se cierra el fichero antes de cortar
      final ts = DateTime.now().millisecondsSinceEpoch;
      _jsStopRecording('drone_video_$ts.webm');
    }
    await _peerConnection?.close();
    await _wsChannel?.sink.close();
    _peerConnection = null;
    _wsChannel      = null;
    setState(() {
      _remoteRenderer.srcObject = null;
      _isConnected  = false;
      _isRecording  = false;
      _status       = 'Desconectado';
    });
  }

  // Se llama al cerrar la pantalla: corta la conexión y libera el renderer
  @override
  void dispose() {
    _disconnect();
    _remoteRenderer.dispose();
    super.dispose();
  }

  // ── UI ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('WebRTC Demo — Vídeo + YOLO'),
      ),
      body: Column(
        children: [

          // ── ZONA DE VÍDEO ──────────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                // Si hay conexión se muestra el stream; si no, el texto de estado
                _isConnected
                    ? RTCVideoView(_remoteRenderer,
                        objectFit: RTCVideoViewObjectFit
                            .RTCVideoViewObjectFitContain)
                    : Center(child: Text(_status,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18))),

                // Flash blanco que aparece un instante al capturar
                if (_showCaptureFlash)
                  Container(color: Colors.white.withValues(alpha: 0.65)),

                // Indicador REC en la esquina mientras se graba
                if (_isRecording)
                  Positioned(
                    top: 12, right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Icon(Icons.circle, color: Colors.white, size: 9),
                        SizedBox(width: 5),
                        Text('REC', style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
                      ]),
                    ),
                  ),

                // Botones de captura y grabación (solo si hay conexión)
                if (_isConnected)
                  Positioned(
                    bottom: 12, left: 12,
                    child: Row(children: [
                      _ActionButton(
                        icon: Icons.camera_alt,
                        tooltip: 'Captura',
                        onTap: _capture,
                      ),
                      const SizedBox(width: 8),
                      _ActionButton(
                        icon: _isRecording
                            ? Icons.stop_circle
                            : Icons.fiber_manual_record,
                        tooltip: _isRecording
                            ? 'Detener grabación'
                            : 'Iniciar grabación',
                        color: _isRecording ? Colors.red : Colors.white,
                        onTap: _toggleRecording,
                      ),
                    ]),
                  ),
              ],
            ),
          ),

          // ── PANEL INFERIOR ─────────────────────────────────────
          Container(
            color: Colors.grey[900],
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // Selector de modo de detección: un chip por modo YOLO
                Row(children: [
                  const Text('Detección:',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: 10),
                  _ModeChip(
                    label: 'Todo',
                    icon: Icons.select_all,
                    selected: _mode == DetectionMode.all,
                    enabled: _isConnected,
                    onTap: () {
                      setState(() => _mode = DetectionMode.all);
                      _sendDetectionMode(DetectionMode.all);
                    },
                  ),
                  const SizedBox(width: 6),
                  _ModeChip(
                    label: 'Personas',
                    icon: Icons.person,
                    selected: _mode == DetectionMode.person,
                    enabled: _isConnected,
                    onTap: () {
                      setState(() => _mode = DetectionMode.person);
                      _sendDetectionMode(DetectionMode.person);
                    },
                  ),
                  const SizedBox(width: 6),
                  _ModeChip(
                    label: 'Ninguno',
                    icon: Icons.visibility_off,
                    selected: _mode == DetectionMode.none,
                    enabled: _isConnected,
                    onTap: () {
                      setState(() => _mode = DetectionMode.none);
                      _sendDetectionMode(DetectionMode.none);
                    },
                  ),
                ]),

                const SizedBox(height: 10),

                // Texto de estado + botones de conectar / desconectar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_status,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                    Row(children: [
                      ElevatedButton(
                        onPressed: _isConnected ? null : _connect,
                        child: const Text('Conectar'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        onPressed: _isConnected ? _disconnect : null,
                        child: const Text('Desconectar'),
                      ),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── WIDGET: botón de acción flotante sobre el vídeo (captura / grabar) ──
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

// ── WIDGET: chip seleccionable de modo de detección ────────────────
class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;   // true si es el modo activo (se pinta resaltado)
  final bool enabled;    // false mientras no haya conexión (chip apagado)
  final VoidCallback onTap;

  const _ModeChip({
    required this.label, required this.icon,
    required this.selected, required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.deepPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? Colors.deepPurple
                : (enabled ? Colors.white38 : Colors.white12),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13,
              color: enabled ? Colors.white : Colors.white24),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
            fontSize: 12,
            color: enabled ? Colors.white : Colors.white24,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          )),
        ]),
      ),
    );
  }
}
