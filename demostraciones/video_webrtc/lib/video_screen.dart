import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';


// ============================================================
// TUTORIAL: Video Streaming con WebRTC en Flutter
//
// FLUJO COMPLETO:
//   1. Flutter abre un WebSocket al sender.py (señalización)
//   2. Sender envía una "offer" con la descripción del stream
//   3. Flutter genera un "answer" y lo devuelve por WebSocket
//   4. Handshake completado → el vídeo fluye directamente por WebRTC
//      (el WebSocket ya no interviene más)
//
// REQUISITO: sender.py corriendo en el portátil emisor con
//            la cámara activa y YOLO detectando objetos
// ============================================================


// Cambia esta IP por la IP local del portátil que corre sender.py
const String senderIP = '172.20.10.4';
const int senderPort = 9999;


class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});


  @override
  State<VideoScreen> createState() => _VideoScreenState();
}


class _VideoScreenState extends State<VideoScreen> {


  // RTCVideoRenderer: widget que pinta el stream de vídeo recibido
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();


  // RTCPeerConnection: objeto central que gestiona la conexión WebRTC
  RTCPeerConnection? _peerConnection;


  // WebSocketChannel: solo para el handshake inicial (offer/answer)
  WebSocketChannel? _wsChannel;


  bool _isConnected = false;
  String _status = 'Desconectado';


  @override
  void initState() {
    super.initState();
    _initRenderer();   // el renderer debe inicializarse antes de usarlo
  }


  // PASO 0: Inicializar el renderer de vídeo
  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }


  // PASO 1: Conectar al sender.py por WebSocket e iniciar la negociación WebRTC
  Future<void> _connect() async {
    setState(() => _status = 'Conectando...');


    // Crear la PeerConnection 
    _peerConnection = await createPeerConnection({});


    // Callback que se dispara cuando llega el track de vídeo del sender
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];  // conecta el stream al widget
          _isConnected = true;
          _status = 'Recibiendo vídeo';
        });
      }
    };


    // Abrir el WebSocket hacia sender.py para la señalización
    _wsChannel = WebSocketChannel.connect(
      Uri.parse('ws://$senderIP:$senderPort'),
    );


    // PASO 2: Escuchar mensajes entrantes del sender por WebSocket
    _wsChannel!.stream.listen((message) async {
      final data = json.decode(message);


      // El sender manda su offer y se responde
      if (data['type'] == 'sdp' && data['sdp_type'] == 'offer') {
        await _handleOffer(data);
      }
    });
  }


  // PASO 3: Procesar la offer del sender y devolver un answer
  Future<void> _handleOffer(Map<String, dynamic> data) async {
    setState(() => _status = 'Offer recibida, respondiendo...');


    // Guardar la descripción del sender como descripción remota
    final offer = RTCSessionDescription(data['sdp'], data['sdp_type']);
    await _peerConnection!.setRemoteDescription(offer);


    // Generar respuesta 
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);  // guardar también como descripción local


    // Enviar el answer al sender → handshake completado, arranca el stream
    _wsChannel!.sink.add(json.encode({
      'type': 'sdp',
      'sdp': answer.sdp,
      'sdp_type': answer.type,    
    }));


    setState(() => _status = 'Answer enviado, esperando stream...');
  }


  // Cerrar la conexión WebRTC y el WebSocket, y limpiar el estado
  Future<void> _disconnect() async {
    await _peerConnection?.close();
    await _wsChannel?.sink.close();
    _peerConnection = null;
    _wsChannel = null;
    setState(() {
      _remoteRenderer.srcObject = null;
      _isConnected = false;
      _status = 'Desconectado';
    });
  }


  @override
  void dispose() {
    _disconnect();
    _remoteRenderer.dispose();  
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('WebRTC Demo — Vídeo Streaming'),
      ),
      body: Column(
        children: [


          
          // Muestra el stream si hay conexión, o el estado actual si no
          Expanded(
            child: _isConnected
                ? RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  )
                : Center(
                    child: Text(
                      _status,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
          ),


          // BARRA INFERIOR: estado de la conexión + botones de control
          Container(
            color: Colors.grey[900],
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: _isConnected ? null : _connect,     // deshabilitado si ya conectado
                      child: const Text('Conectar'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: _isConnected ? _disconnect : null,  // deshabilitado si no conectado
                      child: const Text('Desconectar'),
                    ),
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
