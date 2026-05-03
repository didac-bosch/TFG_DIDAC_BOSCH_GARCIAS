class Constants {
  static const String broker = 'broker.hivemq.com';     //cambiar a broker UPC???
  static const int port = 8884;

  // URL de señalización WebRTC (para hacer el handshake con la estación tierra)
  static const String webrtcSignalUrl = 'wss://dronseetac.upc.edu:8105/ws';   

  // Topics publicar
  static const String topicConnect    = 'mobileFlutter/groundStation/connect';
  static const String topicArm        = 'mobileFlutter/groundStation/arm';
  static const String topicTakeoff    = 'mobileFlutter/groundStation/takeoff';
  static const String topicLand       = 'mobileFlutter/groundStation/land';
  static const String topicRTL        = 'mobileFlutter/groundStation/rtl';
  static const String topicSpeed      = 'mobileFlutter/groundStation/speed';
  static const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';
    // Mission
  static const String topicUploadMission = 'mobileFlutter/groundStation/uploadMission';
  static const String topicStartMission  = 'mobileFlutter/groundStation/startMission';

  

  // Topics escuchar
  static const String topicConnected    = 'groundStation/mobileFlutter/connected';
  static const String topicArmed        = 'groundStation/mobileFlutter/armed';
  static const String topicDisarmed     = 'groundStation/mobileFlutter/disarmed';
  static const String topicFlying       = 'groundStation/mobileFlutter/flying';
  static const String topicLanded       = 'groundStation/mobileFlutter/landed';
  static const String topicDisconnected = 'groundStation/mobileFlutter/disconnected';
  // Mission confirmations
  static const String topicMissionUploaded = 'groundStation/mobileFlutter/missionUploaded';
  static const String topicMissionStarted  = 'groundStation/mobileFlutter/missionStarted';
  static const String topicMissionWaypoint = 'groundStation/mobileFlutter/missionWaypoint';
}

