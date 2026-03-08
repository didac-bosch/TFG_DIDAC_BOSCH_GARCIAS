import 'package:flutter/material.dart';
import 'data/mqtt_logic.dart';
import 'core/constants.dart';
import 'dart:async';
import 'dart:convert';
import 'package:latlong2/latlong.dart';

//en lugar de polling HTTP se usa MQTT reactivo: flutter se queda escuchando y reacciona solo cuando llega algo

class DronProvider extends ChangeNotifier {
  final MqttLogic _mqtt = MqttLogic();

  // Estado inicial
  bool isLoading = false;
  String message = "Please connect to a drone";
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
  String currentState = "Unknown";
  String currentMode = "Unknown";
  double currentLat = 0.0;
  double currentLon = 0.0;
  double currentVx = 0.0;
  double currentVy = 0.0;

  List<LatLng> droneTrail = [];

  // Control interno del arm
  bool _waitingForArm = false;
  bool _armConfirmed = false;

  void setAltitude(String altValue) {   //set altitude pero solo si está dentro del margen
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

  void setSpeed(String speedValue) async {    //set speed solo si está dentro del margen
    final speed = double.tryParse(speedValue);
    if (speed == null || speed < 1.0 || speed > 15.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    flightSpeed = speed;
    notifyListeners();

    // Si ya está conectado, se informa al dron de la nueva velocidad
    if (isConnected) {
      _mqtt.publish(Constants.topicSpeed, flightSpeed.toString());
    }
  }

  ///////////// CONNECT /////////////
  Future<void> connectDron() async {
    isLoading = true;
    isFlying = false;
    message = "Trying to connect...";
    notifyListeners();

    try {
      await _mqtt.connect();  // conecta al broker MQTT

      // suscripción a todos los topics de respuesta, para enterarse cuando hay un cambio
      _mqtt.subscribe(Constants.topicTelemetry);
      _mqtt.subscribe(Constants.topicConnected);
      _mqtt.subscribe(Constants.topicArmed);
      _mqtt.subscribe(Constants.topicDisarmed);
      _mqtt.subscribe(Constants.topicFlying);
      _mqtt.subscribe(Constants.topicLanded);
      _mqtt.subscribe(Constants.topicDisconnected);

      _mqtt.onMessageReceived = _handleMessage;   // callback para mensajes entrantes

      _mqtt.publish(Constants.topicConnect, 'connect');   // orden de conexión al dron
    } catch (error) {
      message = "$error";
      isLoading = false;
      notifyListeners();
    }
    // isLoading se desactiva cuando llega 'connected' por MQTT
  }

  ///////////// ARM /////////////
  Future<void> armDron() async {
    if (!isConnected) return;

    isLoading = true;
    isFlying = false;
    message = "Arming...";
    _waitingForArm = true;
    _armConfirmed = false;
    notifyListeners();

    _mqtt.publish(Constants.topicArm, 'arm');
    isLoading = false;
    notifyListeners();

    // Timer para detectar "not ready to arm" si no llega confirmación en 5s
    Timer(const Duration(seconds: 5), () {
      if (_waitingForArm && !_armConfirmed) {
        _waitingForArm = false;
        message = "Not ready to arm";
        notifyListeners();
      }
    });
  }

  ///////////// DISCONNECT /////////////
  Future<void> disconnectDron() async {
    if (!isConnected) return;

    isLoading = true;
    message = "Disconnecting...";
    notifyListeners();

    _mqtt.publish(Constants.topicDisconnect, 'disconnect');
    // isLoading se desactiva cuando llega 'disconnected' por MQTT
  }

  ///////////// TAKEOFF /////////////
  Future<void> takeOff() async {
    if (!isConnected || !isArmed) return;

    isLoading = true;
    message = "Taking off...";
    notifyListeners();

    _mqtt.publish(Constants.topicTakeoff, takeoffAltitude.toInt().toString());
    isLoading = false;
    notifyListeners();
  }

  ///////////// LAND /////////////
  Future<void> land() async {
    if (!isConnected || !isFlying) return;

    isLoading = true;
    message = "Landing...";
    notifyListeners();

    _mqtt.publish(Constants.topicLand, 'land');
    isLoading = false;
    notifyListeners();
  }

  ///////////// RTL /////////////
  Future<void> rtl() async {
    if (!isConnected || !isFlying) return;

    isLoading = true;
    message = "Returning to launch...";
    notifyListeners();

    _mqtt.publish(Constants.topicRTL, 'rtl');
    isLoading = false;
    notifyListeners();
  }

  ///////////// MOVE /////////////
  Future<void> startMove(String direction) async {
    if (!isConnected || !isFlying) return;
    _mqtt.publish(Constants.topicMove, direction);
  }

  Future<void> stopMove() async {
    if (!isConnected || !isFlying) return;
    _mqtt.publish(Constants.topicMove, 'Stop');
  }

  ///////////// HANDLER MENSAJES MQTT ENTRANTES /////////////
  void _handleMessage(String topic, String payload) {
  //procesador de mensajes que se reciben de la estación tierra. Aquí se actualiza la pantalla mediante el notifyListeners

    // TELEMETRÍA
    if (topic == Constants.topicTelemetry) {
      final status = json.decode(payload);
      currentAlt     = (status['alt']               as num).toDouble();
      currentBat     = (status['battery_remaining'] as num).toDouble();
      currentSpeed   = (status['groundSpeed']        as num).toDouble();
      currentHeading = (status['heading']            as num).toDouble();
      currentState   = status['state']     as String;
      currentMode    = status['flightMode'] as String;
      currentLat     = (status['lat'] as num).toDouble();
      currentLon     = (status['lon'] as num).toDouble();
      currentVx      = (status['vx']  as num).toDouble();
      currentVy      = (status['vy']  as num).toDouble();

      if (currentLat != 0.0 && currentLon != 0.0) {
        droneTrail.add(LatLng(currentLat, currentLon));
        if (droneTrail.length > 100) droneTrail.removeAt(0);
      }
      notifyListeners();
      return;
    }

    // CONNECTED
    if (topic == Constants.topicConnected) {
      isConnected = true;
      isLoading = false;
      message = "Connection established!";
      notifyListeners();
      return;
    }

    // ARMED
    if (topic == Constants.topicArmed) {
      if (_waitingForArm) {
        _armConfirmed = true;
        _waitingForArm = false;
        isArmed = true;
        message = "BEWARE, MOTORS ARMED!!!";
        notifyListeners();
      }
      return;
    }

    // DISARMED (desarmado automáticamente)
    if (topic == Constants.topicDisarmed) {
      isArmed = false;
      isFlying = false;
      _armConfirmed = false;
      _waitingForArm = false;
      message = "Motors disarmed automatically";
      notifyListeners();
      return;
    }

    // FLYING
    if (topic == Constants.topicFlying) {
      isFlying = true;
      message = "Flying";
      notifyListeners();
      return;
    }

    // LANDED
    if (topic == Constants.topicLanded) {
      isFlying = false;
      isArmed = false;
      _armConfirmed = false;
      message = "Landed";
      notifyListeners();
      return;
    }

    // DISCONNECTED
    if (topic == Constants.topicDisconnected) {
      isConnected = false;
      isArmed = false;
      isFlying = false;
      isLoading = false;
      _waitingForArm = false;
      _armConfirmed = false;
      currentAlt = 0.0;
      currentBat = 0.0;
      currentSpeed = 0.0;
      currentHeading = 0.0;
      currentState = "Unknown";
      currentMode = "Unknown";
      currentVx = 0.0;
      currentVy = 0.0;
      droneTrail.clear();
      message = "Awaiting orders";
      _mqtt.disconnect();
      notifyListeners();
      return;
    }
  }
}
