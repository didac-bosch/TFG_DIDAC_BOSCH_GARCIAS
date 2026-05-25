import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _myId = 'browser'; //IDs para el handshake webrtc
const String _remoteId = 'python';

class WebRTCLogic {
  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  RTCDataChannel? _joystickChannel;
  RTCDataChannel? _telemetryChannel;

  Function(MediaStream)? onRemoteStream;
  Function(String)? onTelemetry;

  final List<Map<String, dynamic>> _msgQueue = [];
  bool _pcReady = false;

  Future<void> connect(String signalingUrl) async {
    _ws = WebSocketChannel.connect(Uri.parse(signalingUrl));
    _ws!.sink.add(_myId);

    final iceCompleter = Completer<Map<String, dynamic>>();

    // Único listener para todos los mensajes
    _ws!.stream.listen((message) async {
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
    //flutter recibe la offer de la ET y envía la answer para el signaling
    if (data['type'] == 'offer') {
      final offer = data['offer'] as Map;
      await _pc!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _ws!.sink.add(
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
        await _pc!.addCandidate(
          RTCIceCandidate(
            cand['candidate'],
            cand['sdpMid'],
            cand['sdpMLineIndex'],
          ),
        );
      } catch (_) {}
    }
  }

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

  Future<void> disconnect() async {
    _pcReady = false;
    _msgQueue.clear();

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
