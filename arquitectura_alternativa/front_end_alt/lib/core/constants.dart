// ============================================================
// CONSTANTES GLOBALES
//
// Centraliza la dirección del broker MQTT, todos los topics
// usados en la comunicación y la URL de señalización WebRTC.
// Separados en tres grupos:
//   - mobileFlutter/groundStation/... órdenes que envía Flutter
//   - groundStation/mobileFlutter/... respuestas que recibe Flutter
//   - WebRTC: URL de señalización hacia el backend (relay)
// ============================================================

class Constants {
  static const String broker = 'broker.hivemq.com';
  static const int port = 8884;

  // URL de señalización WebRTC — el backend hace relay entre Flutter y la estación tierra
  // Cambiar IP por la del portátil que corre el servidor Dart
  static const String webrtcSignalUrl = 'wss://dronseetac.upc.edu:8104/ws';   

  // Topics publicar
  static const String topicConnect    = 'mobileFlutter/groundStation/connect';
  static const String topicArm        = 'mobileFlutter/groundStation/arm';
  static const String topicTakeoff    = 'mobileFlutter/groundStation/takeoff';
  static const String topicLand       = 'mobileFlutter/groundStation/land';
  static const String topicRTL        = 'mobileFlutter/groundStation/rtl';
  static const String topicSpeed      = 'mobileFlutter/groundStation/speed';
  static const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';

  // Topics escuchar
  static const String topicConnected    = 'groundStation/mobileFlutter/connected';
  static const String topicArmed        = 'groundStation/mobileFlutter/armed';
  static const String topicDisarmed     = 'groundStation/mobileFlutter/disarmed';
  static const String topicFlying       = 'groundStation/mobileFlutter/flying';
  static const String topicLanded       = 'groundStation/mobileFlutter/landed';
  static const String topicDisconnected = 'groundStation/mobileFlutter/disconnected';
}
