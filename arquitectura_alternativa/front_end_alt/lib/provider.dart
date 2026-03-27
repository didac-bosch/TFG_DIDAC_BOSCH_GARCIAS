import 'package:flutter/material.dart';
import 'data/mqtt_logic.dart';
import 'data/webrtc.dart';
import 'core/constants.dart';
import 'dart:async';
import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:geolocator/geolocator.dart';

// ============================================================
// GESTOR DE ESTADO CENTRAL — DronProvider
//
// Gestiona el estado del dron, la telemetría en tiempo real
// y la configuración de vuelo. Todas las órdenes al dron
// pasan por aquí. Coordina dos canales de comunicación:
//   - MQTT: comandos críticos (arm, takeoff, land, rtl...)
//   - WebRTC: joystick a ~20Hz + stream de vídeo
// ============================================================

class DronProvider extends ChangeNotifier {
  final MqttLogic _mqtt = MqttLogic();
  final WebRTCLogic _webrtc = WebRTCLogic();

  // Estado inicial
  bool isLoading = false;
  String message = 'Please connect to a drone';
  bool isConnected = false;
  bool isArmed = false;
  bool isFlying = false;

  // Setup inicial
  double takeoffAltitude = 10.0;
  double flightSpeed = 5.0;
  bool isConfigValid = true;

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

  List<LatLng> droneTrail = [];

  LatLng? userPosition; // null hasta tener GPS
  double userAccuracy = 0; // precisión en metros
  StreamSubscription<Position>? _locationSub;

  // WebRTC — stream de vídeo remoto para flight_screen
  MediaStream? remoteStream;
  bool isVideoActive = false; // controla si se muestra mapa o cámara

  // Control interno del arm
  bool _waitingForArm = false;
  bool _armConfirmed = false;

  // Timer del joystick — envía los ejes a ~20Hz mientras vuela
  Timer? _joystickTimer;

  // valores actuales de los joysticks — se actualizan desde flight_screen
  double _lx = 0.0;
  double _ly = 0.0;
  double _rx = 0.0;
  double _ry = 0.0;

  void setAltitude(String altValue) {
    final alt = double.tryParse(altValue);
    if (alt == null || alt < 2.0 || alt > 50.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    takeoffAltitude = alt;
    notifyListeners();
  }

  void setSpeed(String speedValue) async {
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

  // ============================================================
  // JOYSTICK — actualiza los ejes y arranca/para el timer
  //
  // flight_screen llama a updateJoystick() cada vez que el
  // usuario mueve un joystick. El timer envía los valores
  // por WebRTC a 20Hz de forma independiente al framerate
  // ============================================================
  void updateJoystick({double? lx, double? ly, double? rx, double? ry}) {
    if (lx != null) _lx = lx;
    if (ly != null) _ly = ly;
    if (rx != null) _rx = rx;
    if (ry != null) _ry = ry;
  }

  void _startJoystickTimer() {
    // envía los ejes a 20Hz — cada 50ms
    _joystickTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _webrtc.sendJoystick(_lx, _ly, _rx, _ry),
    );
  }

  void _stopJoystickTimer() {
    _joystickTimer?.cancel();
    _joystickTimer = null;
    // manda un frame de reposo al parar para asegurar que el dron se detiene
    _webrtc.sendJoystick(0, 0, 0, 0);
  }

  // ============================================================
  // CONNECT — conecta MQTT y WebRTC en paralelo
  // ============================================================
  Future<void> connectDron() async {
    isLoading = true;
    isFlying = false;
    message = 'Trying to connect...';
    notifyListeners();

    try {
      // MQTT — comandos críticos
      await _mqtt.connect();
      _mqtt.subscribe(Constants.topicConnected);
      _mqtt.subscribe(Constants.topicArmed);
      _mqtt.subscribe(Constants.topicDisarmed);
      _mqtt.subscribe(Constants.topicFlying);
      _mqtt.subscribe(Constants.topicLanded);
      _mqtt.subscribe(Constants.topicDisconnected);
      _mqtt.onMessageReceived = _handleMessage;
      _mqtt.publish(Constants.topicConnect, 'connect');

      // WebRTC — joystick + vídeo
      _webrtc.onRemoteStream = (stream) {
        remoteStream = stream;
        notifyListeners(); // avisa a flight_screen que el vídeo está disponible
      };
      _webrtc.onTelemetry = (jsonStr) {
        _handleTelemetry(jsonStr); // nueva función privada
      };

      await _webrtc.connect(Constants.webrtcSignalUrl);
      startUserLocation();

    } catch (error) {
      message = '$error';
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// ARM /////////////
  Future<void> armDron() async {
    if (!isConnected) return;
    isLoading = true;
    isFlying = false;
    message = 'Arming...';
    _waitingForArm = true;
    _armConfirmed = false;
    notifyListeners();

    _mqtt.publish(Constants.topicArm, 'arm');
    isLoading = false;
    notifyListeners();

    // timer para detectar "not ready to arm" si no llega confirmación en 5s
    Timer(const Duration(seconds: 5), () {
      if (_waitingForArm && !_armConfirmed) {
        _waitingForArm = false;
        message = 'Not ready to arm';
        notifyListeners();
      }
    });
  }

  ///////////// DISCONNECT /////////////
  Future<void> disconnectDron() async {
    if (!isConnected) return;
    isLoading = true;
    message = 'Disconnecting...';
    notifyListeners();

    _stopJoystickTimer();
    await _webrtc.disconnect();
    _mqtt.publish(Constants.topicDisconnect, 'disconnect');
  }

  ///////////// TAKEOFF /////////////
  Future<void> takeOff() async {
    if (!isConnected || !isArmed) return;
    isLoading = true;
    message = 'Taking off...';
    notifyListeners();

    _mqtt.publish(Constants.topicTakeoff, takeoffAltitude.toInt().toString());
    isLoading = false;
    notifyListeners();
  }

  ///////////// LAND /////////////
  Future<void> land() async {
    if (!isConnected || !isFlying) return;
    isLoading = true;
    message = 'Landing...';
    notifyListeners();

    _stopJoystickTimer();
    _mqtt.publish(Constants.topicLand, 'land');
    isLoading = false;
    notifyListeners();
  }

  ///////////// RTL /////////////
  Future<void> rtl() async {
    if (!isConnected || !isFlying) return;
    isLoading = true;
    message = 'Returning to launch...';
    notifyListeners();

    _stopJoystickTimer();
    _mqtt.publish(Constants.topicRTL, 'rtl');
    isLoading = false;
    notifyListeners();
  }

  // swap mapa/cámara
  void toggleVideo() {
    isVideoActive = !isVideoActive;
    notifyListeners();
  }

  ///////////// HANDLER MENSAJES MQTT ENTRANTES /////////////
  void _handleMessage(String topic, String payload) {
    // CONNECTED
    if (topic == Constants.topicConnected) {
      isConnected = true;
      isLoading = false;
      message = 'Connection established!';
      notifyListeners();
      return;
    }

    // ARMED
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

    // DISARMED
    if (topic == Constants.topicDisarmed) {
      isArmed = false;
      isFlying = false;
      _armConfirmed = false;
      _waitingForArm = false;
      message = 'Motors disarmed automatically';
      notifyListeners();
      return;
    }

    // FLYING — arranca el timer del joystick al despegar
    if (topic == Constants.topicFlying) {
      isFlying = true;
      message = 'Flying';
      _startJoystickTimer();
      notifyListeners();
      return;
    }

    // LANDED
    if (topic == Constants.topicLanded) {
      isFlying = false;
      isArmed = false;
      _armConfirmed = false;
      message = 'Landed';
      notifyListeners();
      return;
    }

    // DISCONNECTED
    if (topic == Constants.topicDisconnected) {
      isConnected = false;
      isArmed = false;
      isFlying = false;
      isLoading = false;
      isVideoActive = false;
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

  Future<void> startUserLocation() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _locationSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 1,
          ),
        ).listen((Position pos) {
          userAccuracy = pos.accuracy;
          // primera posición: siempre aceptar; resto: filtrar si error > 50m
          if (userPosition != null && pos.accuracy > 50) {
            notifyListeners(); // actualiza badge de precisión igualmente
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
