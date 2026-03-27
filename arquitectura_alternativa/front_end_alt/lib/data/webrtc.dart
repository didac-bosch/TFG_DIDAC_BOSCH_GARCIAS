import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _myId     = 'browser'; //flutter
const String _remoteId = 'python';  //destinatario

class WebRTCLogic {   
  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  RTCDataChannel? _joystickChannel;
  RTCDataChannel? _telemetryChannel;

  // Callbacks
  Function(MediaStream)? onRemoteStream;
  Function(String)? onTelemetry;  

  Future<void> connect(String signalingUrl) async {
    _ws = WebSocketChannel.connect(Uri.parse(signalingUrl));
    _ws!.sink.add(_myId);   //registro primer peer

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},     //convertir a servidor TURN???
      ],
    };

    _pc = await createPeerConnection(config);   

    _pc!.onTrack = (event) {        //empieza a escuchar stream de video
      if (event.streams.isNotEmpty) {
        onRemoteStream?.call(event.streams[0]);
      }
    };

    // Separar DataChannels por label
    _pc!.onDataChannel = (channel) {    //empiesza aescuchar los datachannels
      if (channel.label == 'joystick') {
        _joystickChannel = channel;
      } else if (channel.label == 'telemetry') {
        _telemetryChannel = channel;
        _telemetryChannel!.onMessage = (RTCDataChannelMessage message) {
          onTelemetry?.call(message.text);
        };
      }
    };

    _pc!.onIceCandidate = (candidate) {           //envío de ICEcandidates
      if (candidate.candidate == null) return;
      _ws!.sink.add(jsonEncode({
        'target': _remoteId,
        'type':   'candidate',
        'candidate': {
          'candidate':     candidate.candidate,
          'sdpMid':        candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      }));
    };

    _ws!.stream.listen((message) async {      //mensajes del ws para añadire ICEcandidate o procesar offer
      final data = jsonDecode(message as String) as Map;

      if (data['type'] == 'offer') {      
        final offer = data['offer'] as Map;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(offer['sdp'], offer['type']),
        );
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        _ws!.sink.add(jsonEncode({
          'target': _remoteId,
          'type':   'answer',
          'answer': {
            'sdp':  answer.sdp,
            'type': answer.type,
          },
        }));
      }

      if (data['type'] == 'candidate') {
        final cand = data['candidate'] as Map?;
        if (cand == null) return;
        await _pc!.addCandidate(RTCIceCandidate(
          cand['candidate'],
          cand['sdpMid'],
          cand['sdpMLineIndex'],
        ));
      }
    });
  }

  void sendJoystick(double lx, double ly, double rx, double ry) {   //joysticks
    if (_joystickChannel == null) return;
    if (_joystickChannel!.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _joystickChannel!.send(RTCDataChannelMessage(jsonEncode({
      'lx': lx,
      'ly': ly,
      'rx': rx,
      'ry': ry,
    })));
  }

  Future<void> disconnect() async { //desconexión
    await _pc?.close();
    await _ws?.sink.close();
    _pc              = null;
    _ws              = null;
    _joystickChannel = null;
    _telemetryChannel = null;
  }
}
