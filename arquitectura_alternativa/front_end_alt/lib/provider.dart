import 'package:flutter/material.dart';
import 'data/mqtt_logic.dart';
import 'data/webrtc.dart';
import 'core/constants.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';                     
import 'package:latlong2/latlong.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:geolocator/geolocator.dart';


// Llamada a funciones JavaScript declaradas en el index.html relacionadas con la captura de pantalla 
@JS('captureDroneFrame')
external void _jsCapture(String filename);

@JS('startDroneRecording')
external void _jsStartRecording();

@JS('stopDroneRecording')
external void _jsStopRecording(String filename);


// Modos de control 
enum ControlMode { classic, voice, imu }

// Modos de detección YOLO — sincronizados con ET via MQTT
enum DetectionMode { all, person, none }


class DronProvider extends ChangeNotifier {
  final MqttLogic _mqtt = MqttLogic();  //gestión conexión mqtt
  final WebRTCLogic _webrtc = WebRTCLogic();  //gestión conexión webRTC

  //estados de conexión y vuelo
  bool isLoading = false;
  String message = 'Please connect to a drone';
  bool isConnected = false;
  bool isArmed = false;
  bool isFlying = false;

  double takeoffAltitude = 10.0;
  double flightSpeed = 5.0;
  bool isConfigValid = true;

  ControlMode selectedMode = ControlMode.classic; //selección por defecto

  void setControlMode(ControlMode mode) {
    selectedMode = mode;
    notifyListeners();  //notify para refrescar la pantalla 
  }

  // Telemetría
  double currentAlt = 0.0;
  double currentBat = 0.0;
  double currentSpeed = 0.0;
  double currentHeading = 0.0;
  String currentState = 'Unknown';
  String currentMode = 'Unknown';
  double currentLat = 0.0;
  double currentLon = 0.0;
  double currentVx = 0.0;
  double currentVy = 0.0;

  List<LatLng> droneTrail = []; //historial posiciones

  //posicionamiento usuario 
  LatLng? userPosition;
  double userAccuracy = 0;
  StreamSubscription<Position>? _locationSub;

  // WebRTC
  MediaStream? remoteStream;
  bool isVideoActive = false;

  // Grabación parada por defecto
  bool isRecording = false;

  // Modo detección por defecto 
  DetectionMode detectionMode = DetectionMode.all;

  bool _waitingForArm = false;
  bool _armConfirmed = false;

  //timer y valores del joystick 
  Timer? _joystickTimer;
  double _lx = 0.0;
  double _ly = 0.0;
  double _rx = 0.0;
  double _ry = 0.0;


  void setAltitude(String altValue) {   //setter de altitud 
    final alt = double.tryParse(altValue);
    if (alt == null || alt < 2.0 || alt > 50.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    takeoffAltitude = alt;  //actualización takeoff alt y pantalla 
    notifyListeners();
  }

  void setSpeed(String speedValue) async {  //setter de la velocidad
    final speed = double.tryParse(speedValue);
    if (speed == null || speed < 1.0 || speed > 15.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    flightSpeed = speed;
    notifyListeners();
    if (isConnected) {
      _mqtt.publish(Constants.topicSpeed, flightSpeed.toString());
    }
  }

  void updateJoystick({double? lx, double? ly, double? rx, double? ry}) { //actualización independiente de cada valor del joystick 
    if (lx != null) _lx = lx;
    if (ly != null) _ly = ly;
    if (rx != null) _rx = rx;
    if (ry != null) _ry = ry;
  }

  void _startJoystickTimer() {
    _joystickTimer = Timer.periodic(
      const Duration(milliseconds: 50),                   // Lee vlaores del joystick cada 50ms
      (_) => _webrtc.sendJoystick(_lx, _ly, _rx, _ry),
    );
  }

  void _stopJoystickTimer() {
    _joystickTimer?.cancel();
    _joystickTimer = null;
    _webrtc.sendJoystick(0, 0, 0, 0);
  }


  // -----------------------CONECTAR----------------------------------
  Future<void> connectDron() async {
    isLoading = true;
    isFlying = false;
    message = 'Trying to connect...';
    notifyListeners();

    try {     //conexión con broker y suscripciones mqtt
      await _mqtt.connect();
      _mqtt.subscribe(Constants.topicConnected);
      _mqtt.subscribe(Constants.topicArmed);
      _mqtt.subscribe(Constants.topicDisarmed);
      _mqtt.subscribe(Constants.topicFlying);
      _mqtt.subscribe(Constants.topicLanded);
      _mqtt.subscribe(Constants.topicDisconnected);
      _mqtt.onMessageReceived = _handleMessage;

      _mqtt.publish(Constants.topicConnect, 'connect'); 


      //registro callbacks webrtc 
      _webrtc.onRemoteStream = (stream) {
        remoteStream = stream;
        notifyListeners();
      };
      _webrtc.onTelemetry = (jsonStr) {
        _handleTelemetry(jsonStr);
      };

      await _webrtc.connect(Constants.webrtcSignalUrl);
      startUserLocation();

    } catch (error) {
      message = '$error';
      isLoading = false;
      notifyListeners();
    }
  }


  // -----------------------ARMAR----------------------------------
  Future<void> armDron() async {
    if (!isConnected) return;
    isLoading = true;
    isFlying = false;
    message = 'Arming...';
    _waitingForArm = true;
    _armConfirmed = false;
    notifyListeners();

    _mqtt.publish(Constants.topicArm, 'arm'); //publicación armar
    isLoading = false;
    notifyListeners();

    Timer(const Duration(seconds: 5), () {    //Si en 5s no se ha devuelto una confirmación, se supone que no se está preparado para armar
      if (_waitingForArm && !_armConfirmed) {
        _waitingForArm = false;
        message = 'Not ready to arm';
        notifyListeners();
      }
    });
  }

  // -----------------------DESCONECTAR----------------------------------
  Future<void> disconnectDron() async {
    if (!isConnected) return;
    isLoading = true;
    message = 'Disconnecting...';
    notifyListeners();

    _stopJoystickTimer();
    await _webrtc.disconnect();
    _mqtt.publish(Constants.topicDisconnect, 'disconnect');
  }

  // -----------------------DESPEGAR----------------------------------
  Future<void> takeOff() async {
    if (!isConnected || !isArmed) return;
    isLoading = true;
    message = 'Taking off...';
    notifyListeners();

    _mqtt.publish(Constants.topicTakeoff, takeoffAltitude.toInt().toString());    //publicación despegar junto con altitud de despegue 
    isLoading = false;
    notifyListeners();
  }

  // -----------------------ATERRIZAR----------------------------------
  Future<void> land() async {
    if (!isConnected || !isFlying) return;
    isLoading = true;
    message = 'Landing...';
    notifyListeners();

    _stopJoystickTimer(); //deja de escuchar a los joysticjs 
    _mqtt.publish(Constants.topicLand, 'land');
    isLoading = false;
    notifyListeners();
  }

  // -----------------------RTL----------------------------------
  Future<void> rtl() async {
    if (!isConnected || !isFlying) return;
    isLoading = true;
    message = 'Returning to launch...';
    notifyListeners();

    _stopJoystickTimer(); //deja de escuchar a los joystick 
    _mqtt.publish(Constants.topicRTL, 'rtl');
    isLoading = false;
    notifyListeners();
  }

    // -----------------------Swap entre mapa y vídeo----------------------------------

  void toggleVideo() {
    isVideoActive = !isVideoActive;
    notifyListeners();
  }


// Modo detección YOLO
  void setDetectionMode(DetectionMode mode) {
    detectionMode = mode;
    final modeStr = switch (mode) {
      DetectionMode.all    => 'all',
      DetectionMode.person => 'person',
      DetectionMode.none   => 'none',
    };
    // topic: mobileFlutter/groundStation/detectionMode
    _mqtt.publish('mobileFlutter/groundStation/detectionMode', modeStr);
    notifyListeners();
  }


  void capturePhoto() { //captura 
    final ts = DateTime.now().millisecondsSinceEpoch;
    _jsCapture('drone_capture_$ts.png');
    message = '!Photo saved!';
    notifyListeners();
  }

  void startRecording() { //video
    if (isRecording) return;
    _jsStartRecording();
    isRecording = true;
    message = 'Recording...';
    notifyListeners();
  }

  void stopRecording() {
    if (!isRecording) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _jsStopRecording('drone_video_$ts.webm');
    isRecording = false;
    message = '!Video saved!';
    notifyListeners();
  }


  // -----------------------HANDLER DE MENSAJES----------------------------------
  void _handleMessage(String topic, String payload) {

    if (topic == Constants.topicConnected) {
      isConnected = true;
      isLoading = false;
      message = 'Connection established!';
      notifyListeners();
      return;
    }

    if (topic == Constants.topicArmed) {
      if (_waitingForArm) {
        _armConfirmed = true;
        _waitingForArm = false;
        isArmed = true;
        message = 'BEWARE, MOTORS ARMED!!!';
        notifyListeners();
      }
      return;
    }

    if (topic == Constants.topicDisarmed) {
      isArmed = false;
      isFlying = false;
      _armConfirmed = false;
      _waitingForArm = false;
      message = 'Motors disarmed automatically';
      notifyListeners();
      return;
    }

    if (topic == Constants.topicFlying) {
      isFlying = true;
      message = 'Flying';
      _startJoystickTimer();
      notifyListeners();
      return;
    }

    if (topic == Constants.topicLanded) {
      isFlying = false;
      isArmed = false;
      _armConfirmed = false;
      message = 'Landed';
      notifyListeners();
      return;
    }

    if (topic == Constants.topicDisconnected) {
      isConnected = false;
      isArmed = false;
      isFlying = false;
      isLoading = false;
      isVideoActive = false;
      isRecording = false;            
      detectionMode = DetectionMode.all; 
      _waitingForArm = false;
      _armConfirmed = false;
      currentAlt = 0.0;
      currentBat = 0.0;
      currentSpeed = 0.0;
      currentHeading = 0.0;
      currentState = 'Unknown';
      currentMode = 'Unknown';
      currentVx = 0.0;
      currentVy = 0.0;
      droneTrail.clear();
      remoteStream = null;
      message = 'Awaiting orders';
      _mqtt.disconnect();
      stopUserLocation();
      notifyListeners();
      return;
    }
  }

  // -----------------------HANDLER DE TELEMETRIA----------------------------------
  void _handleTelemetry(String jsonStr) {
    final status = jsonDecode(jsonStr);
    currentAlt = (status['alt'] as num).toDouble();
    currentBat = (status['battery_remaining'] as num).toDouble();
    currentSpeed = (status['groundSpeed'] as num).toDouble();
    currentHeading = (status['heading'] as num).toDouble();
    currentState = status['state'] as String;
    currentMode = status['flightMode'] as String;
    currentLat = (status['lat'] as num).toDouble();
    currentLon = (status['lon'] as num).toDouble();
    currentVx = (status['vx'] as num).toDouble();
    currentVy = (status['vy'] as num).toDouble();

    if (currentLat != 0.0 && currentLon != 0.0) {
      droneTrail.add(LatLng(currentLat, currentLon));
      if (droneTrail.length > 100) droneTrail.removeAt(0);
    }
    notifyListeners();
  }

  // Locaclización usuario 
  Future<void> startUserLocation() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,  //actualizar cada metro 
      ),
    ).listen((Position pos) {
      userAccuracy = pos.accuracy;
      if (userPosition != null && pos.accuracy > 50) {  //si la precisión es mayor a 50m ignorar
        notifyListeners();
        return;
      }
      userPosition = LatLng(pos.latitude, pos.longitude);
      notifyListeners();
    });
  }

  void stopUserLocation() {
    _locationSub?.cancel();
    _locationSub = null;
  }
}