import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';

@JS('requestMotionPermission')
external void requestMotionPermission();

@JS('stopOrientation')
external void stopOrientation();

@JS('getAlpha')
external double getAlpha();

@JS('getBeta')
external double getBeta();

@JS('getGamma')
external double getGamma();

// ============================================================
// IMU DEMO — Lee los ángulos del dispositivo desde el navegador
//
// Usa la API DeviceOrientationEvent del navegador (via puente
// JS definido en web/index.html) para leer los tres ángulos
// de orientación del dispositivo móvil:
//   - PITCH (beta):  inclinación adelante/atrás  [-180°, 180°]
//   - ROLL  (gamma): inclinación izquierda/dcha   [-90°,  90°]
//   - YAW   (alpha): rotación horizontal          [0°,   360°]
//
// Los valores son pre-procesados por el navegador combinando
// acelerómetro, giroscopio y magnetómetro (fusión sensorial).
// Flutter los lee a 20Hz mediante polling con un Timer.
//
// ── COMPATIBILIDAD ──────────────────────────────────────────
//   - Android + Chrome: funciona sin permisos adicionales
//   - iOS + Safari:     requiere pulsar "ACTIVAR SENSORES"
//                       (DeviceOrientationEvent.requestPermission
//                       gestionado en web/index.html)
//   NOTA: DeviceOrientationEvent requiere HTTPS.
//         En producción (EZDrone con HTTPS) funciona directo.
//         En desarrollo local usar ngrok (ver instrucciones).
//
// ── CÓMO PROBARLO EN UN MÓVIL ───────────────────────────────
//   1. Instalar ngrok (solo la primera vez):
//        brew install ngrok
//        ngrok config add-authtoken <TU_TOKEN>
//   2. Arrancar el servidor Flutter:
//        flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0
//   3. En otra terminal, crear el túnel HTTPS:
//        ngrok http 8080
//   4. Ngrok mostrará una URL del tipo:
//        https://a1b2c3d4.ngrok.io
//   5. Abrir esa URL en Safari (iOS) o Chrome (Android)
//   6. Pulsar "ACTIVAR SENSORES" → conceder permiso → mover el móvil
//
//   NOTA: cada sesión de ngrok dura 2h sin cuenta gratuita.
//         Al expirar, repetir pasos 3-6 con la nueva URL.
//
// ── CÓMO ADAPTAR A EZDRONE ──────────────────────────────────
//   - Mapear pitch y roll a PWM: 1500 + valor_normalizado * 500
//   - Enviar los valores por WebRTC DataChannel a ~20Hz
//     (el Timer ya corre a 20Hz, solo añadir el send)
//   - Sustituir el joystick derecho de EZDrone por este control
// ============================================================


void main() {
  runApp(const MaterialApp(
    home: ImuDemo(),
  ));
}

class ImuDemo extends StatefulWidget {
  const ImuDemo({super.key});
  @override
  State<ImuDemo> createState() => _ImuDemoState();
}

class _ImuDemoState extends State<ImuDemo> {
  double _pitch = 0.0;
  double _roll  = 0.0;
  double _yaw   = 0.0;
  bool _active  = false;
  Timer? _timer;

  void _requestAndStart() {
    requestMotionPermission();
    // Poll els valors JS cada 50ms (20Hz)
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      setState(() {
        _yaw   = getAlpha();
        _pitch = getBeta();
        _roll  = getGamma();
        _active = true;
      });
    });
  }

  void _stopListening() {
    stopOrientation();
    _timer?.cancel();
    setState(() {
      _active = false;
      _pitch  = 0.0;
      _roll   = 0.0;
      _yaw    = 0.0;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('IMU Demo', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF2A2A3E),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildAngleBox('PITCH', _pitch, Colors.blue),
                _buildAngleBox('ROLL',  _roll,  Colors.green),
                _buildAngleBox('YAW',   _yaw,   Colors.orange),
              ],
            ),
            const SizedBox(height: 48),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _active ? Colors.red : Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              ),
              onPressed: _active ? _stopListening : _requestAndStart,
              child: Text(
                _active ? 'DETENER' : 'ACTIVAR SENSORES',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAngleBox(String label, double value, Color color) {
    return Container(
      width: 100,
      height: 120,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            '${value.toStringAsFixed(1)}°',
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
