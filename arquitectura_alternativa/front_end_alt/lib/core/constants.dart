class Constants {
  static const String broker = 'broker.hivemq.com';
  static const int port = 1883;

  // Topics publicar 
  static const String topicConnect    = 'mobileFlutter/groundStation/connect';
  static const String topicArm        = 'mobileFlutter/groundStation/arm';
  static const String topicTakeoff    = 'mobileFlutter/groundStation/takeoff';
  static const String topicLand       = 'mobileFlutter/groundStation/land';
  static const String topicRTL        = 'mobileFlutter/groundStation/rtl';
  static const String topicSpeed      = 'mobileFlutter/groundStation/speed';
  static const String topicMove       = 'mobileFlutter/groundStation/move';
  static const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';

  // Topics escuchar 
  static const String topicTelemetry   = 'groundStation/mobileFlutter/telemetry';
  static const String topicConnected   = 'groundStation/mobileFlutter/connected';
  static const String topicArmed       = 'groundStation/mobileFlutter/armed';
  static const String topicDisarmed    = 'groundStation/mobileFlutter/disarmed';
  static const String topicFlying      = 'groundStation/mobileFlutter/flying';
  static const String topicLanded      = 'groundStation/mobileFlutter/landed';
  static const String topicDisconnected= 'groundStation/mobileFlutter/disconnected';
}
