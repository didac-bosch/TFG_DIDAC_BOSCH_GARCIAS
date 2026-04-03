import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================
// TUTORIAL: Vídeo WebRTC + YOLO + captura + grabación
//
// FEATURES:
// 1. Stream WebRTC con detección YOLO (All / Solo personas / Ninguno)
// 2. Captura de pantalla → PNG descargado en Descargas
// 3. Grabación de vídeo  → WebM descargado en Descargas
//
// La captura y grabación ocurren 100% en el cliente (JS Interop):
//   index.html expone captureDroneFrame() y startDroneRecording()
//   Dart llama a estas funciones sin tocar Python
//
// REQUISITO: añadir en index.html las funciones JS correspondientes
// ============================================================

const String senderIP = '192.168.0.84';
const int senderPort  = 9999;

// ── JS Interop — funciones definidas en index.html ─────────────────
@JS('captureDroneFrame')
external void _jsCapture(String filename);

@JS('startDroneRecording')
external void _jsStartRecording();

@JS('stopDroneRecording')
external void _jsStopRecording(String filename);

// Tres modos de detección YOLO
enum DetectionMode { all, person, none }

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  WebSocketChannel? _wsChannel;

  bool   _isConnected      = false;
  String _status            = 'Desconectado';
  DetectionMode _mode       = DetectionMode.all;
  bool   _isRecording       = false;
  bool   _showCaptureFlash  = false;

  @override
  void initState() {
    super.initState();
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

  // ── ENVÍO DE COMANDOS A PYTHON ─────────────────────────────────
  void _sendCommand(Map<String, dynamic> cmd) {
    _wsChannel?.sink.add(json.encode(cmd));
  }

  // ── CONEXIÓN ───────────────────────────────────────────────────
  Future<void> _connect() async {
    setState(() => _status = 'Conectando...');
    _peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    });

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

    _wsChannel!.stream.listen((message) async {
      final data = json.decode(message);
      if (data['type'] == 'sdp' && data['sdp_type'] == 'offer') {
        await _handleOffer(data);
      }
    });
  }

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
    // Sincronizar modo de detección inicial
    _sendDetectionMode(_mode);
  }

  // ── MODO DE DETECCIÓN ──────────────────────────────────────────
  void _sendDetectionMode(DetectionMode mode) {
    final str = switch (mode) {
      DetectionMode.all    => 'all',
      DetectionMode.person => 'person',
      DetectionMode.none   => 'none',
    };
    _sendCommand({'type': 'detection_mode', 'mode': str});
  }

  // ── CAPTURA DE FRAME (JS Interop) ──────────────────────────────
  void _capture() {
    if (!_isConnected) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _jsCapture('drone_capture_$ts.png');
    // Flash blanco de confirmación visual
    setState(() => _showCaptureFlash = true);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _showCaptureFlash = false);
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('📸 Captura guardada en Descargas'),
      duration: Duration(seconds: 2),
      backgroundColor: Colors.green,
    ));
  }

  // ── GRABACIÓN DE VÍDEO (JS Interop) ───────────────────────────
  void _toggleRecording() {
    if (!_isConnected) return;
    if (_isRecording) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _jsStopRecording('drone_video_$ts.webm');
      setState(() => _isRecording = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🎥 Vídeo guardado en Descargas'),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.blue,
      ));
    } else {
      _jsStartRecording();
      setState(() => _isRecording = true);
    }
  }

  // ── DESCONEXIÓN ────────────────────────────────────────────────
  Future<void> _disconnect() async {
    if (_isRecording) {
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
                // Stream o estado
                _isConnected
                    ? RTCVideoView(_remoteRenderer,
                        objectFit: RTCVideoViewObjectFit
                            .RTCVideoViewObjectFitContain)
                    : Center(child: Text(_status,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18))),

                // Flash blanco al capturar
                if (_showCaptureFlash)
                  Container(color: Colors.white.withOpacity(0.65)),

                // Badge REC
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

                // Botones de captura y grabación (solo si conectado)
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

                // Selector de modo de detección
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

                // Estado + botones conectar/desconectar
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

// ── WIDGET: botón de acción sobre el vídeo ─────────────────────────
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

// ── WIDGET: chip de modo de detección ──────────────────────────────
class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
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