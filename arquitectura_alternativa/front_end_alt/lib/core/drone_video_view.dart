import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'js_bridges.dart';

/// Render del stream WebRTC del dron. Crea el elemento `<video>` en el DOM y
/// registra `window._droneStream`, requisitos para que la captura de foto
/// (`captureDroneFrame`, lee `document.querySelector('video')`) y la grabación
/// (`startDroneRecording`, usa `window._droneStream`) funcionen.
///
/// Se usa visible en la FlightScreen y oculto (1×1) durante una misión en la
/// FlightPlanScreen, donde la pantalla muestra el mapa y no habría `<video>`.
class DroneVideoView extends StatefulWidget {
  final MediaStream stream;
  const DroneVideoView({super.key, required this.stream});

  @override
  State<DroneVideoView> createState() => _DroneVideoViewState();
}

class _DroneVideoViewState extends State<DroneVideoView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (!mounted) return;
      _renderer.srcObject = widget.stream;
      setState(() {});
      // Tras pintar el <video>, registrar el stream para la grabación.
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        try {
          setDroneStreamRef();
        } catch (_) {}
      });
    });
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      _renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }
}
