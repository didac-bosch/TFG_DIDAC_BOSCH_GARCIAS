import 'package:flutter/material.dart';
import 'data/http_logic.dart';
import 'dart:async';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';   

// Provider para manejar el estado de la aplicación y la comunicación con el backend
class DronProvider extends ChangeNotifier {
  //notify Listeners() que ayudará a reconstruir todos los widgets que estén suscritos
  final HttpLogic _httpLogic = HttpLogic();

  //Estado inicial
  bool isLoading = false;
  String message = "Please connect to a drone";
  bool isConnected = false;
  bool isArmed = false;
  bool isFlying = false;

  //Setup incial
  double takeoffAltitude = 10.0; //Valores por defecto
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
  DateTime? _armDeadline;
  bool _armConfirmed = false;

  // GPS usuario                              
  LatLng? userPosition;
  double gpsAccuracy = 0;
  StreamSubscription<Position>? _gpsSubscription;

  void setAltitude(String altValue) {   //set altitude pero solo si está dentro del margen
    final alt = double.tryParse(altValue);

    if (alt == null || alt < 2.0 || alt > 50.0) { // si no está dentro del rango, isConfigValid = false
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

    if (speed == null || speed < 1.0 || speed > 15.0) { // si no está dentro del rango, isConfigValid = false
      isConfigValid = false;
      notifyListeners();
      return;
    }

    isConfigValid = true;
    flightSpeed = speed;
    notifyListeners();

    // Si ya está conectado, se infroma al dron de la nueva velocidad
    if (isConnected) {
      try {
        await _httpLogic.sendSpeedRequest(flightSpeed);
      } catch (error) {
        message = "Failed to set speed: $error";
      }
    }
  }

  // GPS del usuario, se solicita permiso y se empieza a escuchar la posición del usuario. Se actualiza userPosition y gpsAccuracy y se notifica a los listeners.
  Future<void> startGPS() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _gpsSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((pos) {
      gpsAccuracy = pos.accuracy;
      if (userPosition != null && pos.accuracy > 50) {
        notifyListeners();
        return;
      }
      userPosition = LatLng(pos.latitude, pos.longitude);
      notifyListeners();
    });
  }

  // para el GPS del usuario, se cancela la suscripción y se limpia userPosition y gpsAccuracy. Se notifica a los listeners.
  void stopGPS() {                             
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    userPosition = null;
    gpsAccuracy = 0;
  }

  ///////////// CONNECT /////////////
  Future<void> connectDron() async {
    isLoading = true; //por si se complica la conexión entra en modo loading
    isFlying = false;
    message = "Trying to connect...";
    notifyListeners();

    try {
      await _httpLogic.sendConnectRequest(); //petición de conexión
      isConnected = true; //si se ha podido connected = true
      message = "Connection established!";
      startPolling(); // empieza a recibir telemetría y posición al conectar
      startGPS();     // ← NUEVO: arranca GPS al conectar
    } catch (error) {
      message = "$error";
    } finally {
      isLoading =
          false; //tanto si funciona como si no, loading = false y se notifica listeners para actualizar
      notifyListeners();
    }
  }

  ///////////// ARM /////////////
  Future<void> armDron() async {
    if (!isConnected) {
      return; //solo deja armar si está conectado, sino retorna null
    }

    isLoading = true;
    isFlying = false;
    message = "Arming..."; //Arming porque puede ser que esté ready to arm o no.

    // Activa la espera del arm con su deadline propio
    _waitingForArm = true;
    _armConfirmed = false;
    _armDeadline = DateTime.now().add(
      const Duration(seconds: 5),
    ); //espera 5 segundos (arm tarda en activarse desde que se pulsa)
    notifyListeners();

    try {
      await _httpLogic.sendArmRequest(); //Petición para armar
    } catch (error) {
      message = "$error";
      _waitingForArm = false;
    } finally {
      isLoading = false; //Tanto si se ha podido o no, deja de cargar
      notifyListeners();
    }
  }

  ///////////// DISCONNECT /////////////
  Future<void> disconnectDron() async {
    if (!isConnected) return; //solo si está conectado

    isLoading = true;
    message = "Disconnecting...";
    notifyListeners();

    try {
      await _httpLogic.sendDisconnectRequest(); //petición de desconexión
      isConnected = false;
      isArmed = false;
      isFlying = false;
      _waitingForArm = false;
      _armConfirmed = false;

      // Limpiar telemetría
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
    } catch (error) {
      message = "$error";
    } finally {
      stopPolling(); //al estar desconectado no necesita saber nada más
      stopGPS();    
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// TAKEOFF /////////////
  Future<void> takeOff() async {
    if (!isConnected || !isArmed) return;

    isLoading = true;
    message = "Taking off...";
    notifyListeners();

    try {
      await _httpLogic.sendTakeoffRequest(takeoffAltitude);
      message = "Taking off to ${takeoffAltitude.toInt()}m";
    } catch (error) {
      message = "$error";
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// LAND /////////////
  Future<void> land() async {
    if (!isConnected || !isFlying) return;

    isLoading = true;
    message = "Landing...";
    notifyListeners();

    try {
      await _httpLogic.sendLandRequest();
      message = "Landing in progress";
    } catch (error) {
      message = "$error";
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// RTL /////////////
  Future<void> rtl() async {
    if (!isConnected || !isFlying) return;

    isLoading = true;
    message = "Returning to launch...";
    notifyListeners();

    try {
      await _httpLogic.sendRTLRequest();
      message = "Returning to launch point";
    } catch (error) {
      message = "$error";
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// MOVE /////////////
  Future<void> startMove(String direction) async {
    if (!isConnected || !isFlying) return;
    try {
      await _httpLogic.sendMoveRequest(direction);
    } catch (error) {
      message = "$error";
    }
  }

  /////////// PARAR /////////////
  Future<void> stopMove() async {
    if (!isConnected || !isFlying) return;

    try {
      await _httpLogic.sendMoveRequest("Stop");
    } catch (error) {
      message = "$error";
    }
  }

  ///////////// POLLING /////////////
  Timer? _statusTimer;

  // polling para recibir telemetría y estado del dron cada 500ms. Se actualiza el estado interno y se notifica a los listeners.
  void startPolling() {
    _statusTimer
        ?.cancel(); //para evitar duplicados, cancela timers si se pulsa arm dos veces por ejemplo

    _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!isConnected) {
        stopPolling();
        return;
      }

      try {
        final status = await _httpLogic.getStatus();
        final armed = status['armed'] as bool; //mira si está armado
        final connected = status['connected'] as bool; //mira si está conectado
        final flying = status['flying'] as bool; //mira si está volando

        // Leer telemetría completa
        final alt = (status['alt'] as num).toDouble();
        final bat = (status['bat'] as num).toDouble();
        final spd = (status['spd'] as num).toDouble();
        final hdg = (status['hdg'] as num).toDouble();
        final stateStr = status['state'] as String;
        final modeStr = status['mode'] as String;
        final lat = (status['lat'] as num).toDouble();
        final lon = (status['lon'] as num).toDouble();
        final vx = (status['vx'] as num).toDouble();
        final vy = (status['vy'] as num).toDouble();

        // Se actualiza siempre que esté conectada
        if (isConnected) {
          currentAlt = alt;
          currentBat = bat;
          currentSpeed = spd;
          currentHeading = hdg;
          currentState = stateStr;
          currentMode = modeStr;
          currentLat = lat;
          currentLon = lon;
          if (lat != 0.0 && lon != 0.0) {
            droneTrail.add(LatLng(lat, lon));
            if (droneTrail.length > 100) droneTrail.removeAt(0);
          }
          currentVx = vx; 
          currentVy = vy; 
          notifyListeners();
        }

        //posibilidades:

        //no conectado (y por tanto no armado)
        if (!connected) {
          isConnected = false;
          isArmed = false;
          isFlying = false;
          _waitingForArm = false;
          _armConfirmed = false;
          message = "Awaiting orders";
          stopPolling();
          stopGPS();    
          notifyListeners();
          return;
        }

        // Lógica de arm - solo activa si se ha pulsado el botón ARM
        if (_waitingForArm) {
          //armado pero no se ha confirmado que está armado (mission planner tarda en armar entonces
          //hasta que no se ha armado no se actualiza el código a armado!)
          if (armed && !_armConfirmed) {
            _armConfirmed = true;
            _waitingForArm = false;
            isArmed = true;
            message = "BEWARE, MOTORS ARMED!!!";
            notifyListeners();
          }

          // Cuando no deja armar y ha pasado la deadLine, significa que no está ready to arm!
          if (!_armConfirmed && DateTime.now().isAfter(_armDeadline!)) {
            _waitingForArm = false;
            message = "Not ready to arm";
            notifyListeners();
          }
        }

        //arm confirmado pero en mission planner no está armado, significa que se acaban de desarmar automáticamente,
        //se desactiva el estado de armado en la web y sale que se han desarmado automáticamente!
        if (_armConfirmed && !armed) {
          isArmed = false;
          isFlying = false;
          _armConfirmed = false;
          _waitingForArm = false;
          message = "Motors disarmed automatically";
          notifyListeners();
          return;
        }

        if (flying != isFlying) {
          isFlying = flying;
          if (flying) {
            message = "Flying";
          } else {
            message = "Landed";
          }
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }
}
