
// Constantes globales para la aplicación, como la configuración del broker MQTT, los topics de publicación y suscripción, y la URL de señalización WebRTC.
class Constants {
  static const String broker = 'broker.hivemq.com'; //cambiar a broker UPC???
  static const int port = 8884;

  // URL de señalización WebRTC (para hacer el handshake con la estación tierra)
  static const String webrtcSignalUrl = 'wss://dronseetac.upc.edu:8105/ws';

  // ---------------Topics publicar------------------------
  // Comandos de control
  static const String topicConnect = 'mobileFlutter/groundStation/connect';
  static const String topicArm = 'mobileFlutter/groundStation/arm';
  static const String topicTakeoff = 'mobileFlutter/groundStation/takeoff';
  static const String topicLand = 'mobileFlutter/groundStation/land';
  static const String topicRTL = 'mobileFlutter/groundStation/rtl';
  static const String topicSpeed = 'mobileFlutter/groundStation/speed';
  static const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';
  // Mission
  static const String topicUploadMission = 'mobileFlutter/groundStation/uploadMission';
  static const String topicStartMission = 'mobileFlutter/groundStation/startMission';
  // Tello
  static const String topicFlip = 'mobileFlutter/groundStation/flip';
  static const String topicOrbit = 'mobileFlutter/groundStation/orbit';
  static const String topicFollowMode = 'mobileFlutter/groundStation/followMode';
  // Panorama 360 — publicar: 'start' | 'stop'
  static const String topicPanorama = 'mobileFlutter/groundStation/panorama360';

  // Camera
  static const String topicSetCamera = 'mobileFlutter/groundStation/setCamera';
  static const String topicSetZoom = 'mobileFlutter/groundStation/zoom';
  static const String topicDetectionMode = 'mobileFlutter/groundStation/detectionMode';
  // Control de vuelo
  static const String topicSetMode = 'mobileFlutter/groundStation/setMode';


  // ---------------Topics escuchar------------------------
  // Confirmaciones de estado
  static const String topicConnected = 'groundStation/mobileFlutter/connected';
  static const String topicArmed = 'groundStation/mobileFlutter/armed';
  static const String topicDisarmed = 'groundStation/mobileFlutter/disarmed';
  static const String topicFlying = 'groundStation/mobileFlutter/flying';
  static const String topicLanded = 'groundStation/mobileFlutter/landed';
  static const String topicDisconnected = 'groundStation/mobileFlutter/disconnected';
  // Mission confirmations
  static const String topicMissionUploaded = 'groundStation/mobileFlutter/missionUploaded';
  static const String topicMissionStarted = 'groundStation/mobileFlutter/missionStarted';
  static const String topicMissionWaypoint = 'groundStation/mobileFlutter/missionWaypoint';
  // Acción de cámara solicitada por la ET durante una misión: 'photo' | 'record:N'
  static const String topicCameraAction = 'groundStation/mobileFlutter/cameraAction';
  // Confirmaciones de modos Tello (autoritativas: 'on' | 'off')
  static const String topicFollowModeStatus = 'groundStation/mobileFlutter/followModeStatus';
  static const String topicOrbitStatus = 'groundStation/mobileFlutter/orbitStatus';
  // Flip — avisos de rechazo (bateria baja / error del dron) para mostrar en la UI
  static const String topicFlipStatus = 'groundStation/mobileFlutter/flipStatus';
  // Panorama 360 — estado del escaneo: 'scanning'|'stitching'|'done'|'error'|'off'
  static const String topicPanoramaStatus = 'groundStation/mobileFlutter/panoramaStatus';
  // Panorama 360 — imagen final cosida (JPEG en base64), para la galería
  static const String topicPanoramaReady = 'groundStation/mobileFlutter/panoramaReady';
}
