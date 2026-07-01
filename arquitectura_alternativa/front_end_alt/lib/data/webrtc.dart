import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// IDs para el handshake de signaling, el browser se identifica como 'browser' y la ET como 'python'
const String _myId = 'browser';
const String _remoteId = 'python';

// Esta clase maneja toda la lógica de WebRTC: conexión, señalización, canales de datos y transmisión de video.
class WebRTCLogic {
  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  // Suscripción al stream del WebSocket: guardarla para cancelarla en
  // disconnect(); si no, el handler async sigue vivo y puede llamar
  // _handleSignaling sobre _pc ya null.
  StreamSubscription? _wsSub;
  RTCDataChannel? _joystickChannel;
  RTCDataChannel? _telemetryChannel;
  Function(MediaStream)? onRemoteStream;
  Function(String)? onTelemetry;

  // Cola para mensajes que llegan antes de que la PeerConnection esté lista
  // Esto es necesario porque el servidor puede enviar mensajes (como candidates) antes de que hayamos recibido la configuración ICE y creado la PeerConnection.
  final List<Map<String, dynamic>> _msgQueue = [];
  bool _pcReady = false;

// Conecta al servidor de signaling y establece la PeerConnection
  Future<void> connect(String signalingUrl) async {
    _ws = WebSocketChannel.connect(Uri.parse(signalingUrl));
    _ws!.sink.add(_myId);

    final iceCompleter = Completer<Map<String, dynamic>>();

    // Único listener para todos los mensajes
    _wsSub = _ws!.stream.listen((message) async {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      // ice_config llega primero, crea la PeerConnection
      if (data['type'] == 'ice_config') {
        if (!iceCompleter.isCompleted) {
          iceCompleter.complete({'iceServers': data['iceServers']});
        }
        return;
      }
      if (!_pcReady) {
        _msgQueue.add(data);
        return;
      }

      await _handleSignaling(data);
    });

    // Esperar ice_config, 3s timeout con fallback a Google STUN
    final config = await iceCompleter.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      },
    );

    await _setupPC(config);

    // Procesar mensajes que llegan mientras se espera
    for (final msg in List.of(_msgQueue)) {
      await _handleSignaling(msg);
    }
    _msgQueue.clear();
  }


  // Configura la PeerConnection con los ICE servers y los handlers para tracks, data channels e ICE candidates
  Future<void> _setupPC(Map<String, dynamic> config) async {
    _pc = await createPeerConnection(config);

    _pc!.onTrack = (event) {
      //video track
      if (event.streams.isNotEmpty) onRemoteStream?.call(event.streams[0]);
    };

    _pc!.onDataChannel = (channel) {
      //Data channels de telemetría y para el joystick
      if (channel.label == 'joystick') {
        _joystickChannel = channel;
      } else if (channel.label == 'telemetry') {
        _telemetryChannel = channel;
        _telemetryChannel!.onMessage = (RTCDataChannelMessage message) {
          onTelemetry?.call(message.text);
        };
      }
    };

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _ws!.sink.add(
        jsonEncode({
          'target': _remoteId,
          'type': 'candidate',
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }),
      );
    };

    _pcReady = true; //listo para procesar mensajes
  }

  Future<void> _handleSignaling(Map<String, dynamic> data) async {
    // Capturar referencias locales: el listener es async y puede estar en vuelo
    // cuando disconnect() pone _pc/_ws a null entre dos awaits → NPE. Usando las
    // locales, si ya se desconectó, simplemente se aborta.
    final pc = _pc;
    final ws = _ws;
    if (pc == null || ws == null) return;

    //flutter recibe la offer de la ET y envía la answer para el signaling
    if (data['type'] == 'offer') {
      final offer = data['offer'] as Map;
      await pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      ws.sink.add(
        jsonEncode({
          'target': _remoteId,
          'type': 'answer',
          'answer': {'sdp': answer.sdp, 'type': answer.type},
        }),
      );
    }

    if (data['type'] == 'candidate') {
      final cand = data['candidate'] as Map?;
      if (cand == null) return;
      try {
        await pc.addCandidate(
          RTCIceCandidate(
            cand['candidate'],
            cand['sdpMid'],
            cand['sdpMLineIndex'],
          ),
        );
      } catch (_) {}
    }
  }

  // Envía los valores del joystick a la ET a través del DataChannel
  void sendJoystick(double lx, double ly, double rx, double ry) {
    //Se convierten los 4 ejes como JSON y se envían por el DataChannel
    if (_joystickChannel == null) return;
    if (_joystickChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    _joystickChannel!.send(
      RTCDataChannelMessage(
        jsonEncode({'lx': lx, 'ly': ly, 'rx': rx, 'ry': ry}),
      ),
    );
  }

  // Cierra la conexión WebRTC y el WebSocket, y limpia los canales de datos
  Future<void> disconnect() async {
    _pcReady = false;
    _msgQueue.clear();

    await _wsSub?.cancel();
    _wsSub = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;

    _joystickChannel = null;
    _telemetryChannel = null;
  }
}
