
// Conjunto constantes para no tener que escribirlas en cada request y poder cambiarlas fácilmente en un futuro
class Constants {
  static const String backendUrl =
      'http://localhost:8080'; //Cambiar a IP correspondiente!!!!

  //COMANDOS
  static const String endpointConnect = '$backendUrl/connect';
  static const String endpointArm = '$backendUrl/arm';
  static const String endpointStatus = '$backendUrl/status';
  static const String endpointDisconnect = '$backendUrl/disconnect';
  static const String endpointTakeoff = '$backendUrl/takeoff';  //ya contiene altitud
  static const String endpointLand = '$backendUrl/land';
  static const String endpointRTL = '$backendUrl/rtl';    
  static const String endpointSpeed = '$backendUrl/speed';
  static const String endpointMove = '$backendUrl/move';


}
