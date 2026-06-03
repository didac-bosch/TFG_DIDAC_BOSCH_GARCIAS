import 'package:flutter/material.dart';
import 'data/mqtt_logic.dart';
import 'data/webrtc.dart';
import 'core/constants.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:latlong2/latlong.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';

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

// Modos de conexión al dron
enum DroneConnectionMode { ardupilot, sitl, tello }

// ------ FLIGHT LOG -------------------
// Snapshot de telemetría — se guarda cada tick mientras el dron está volando
class TelemetrySnapshot {
  final DateTime timestamp;
  final double lat;
  final double lon;
  final double alt;
  final double speed;
  final double bat;
  final double heading;

  TelemetrySnapshot({
    required this.timestamp,
    required this.lat,
    required this.lon,
    required this.alt,
    required this.speed,
    required this.bat,
    required this.heading,
  });

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'alt': alt,
    'speed': speed,
    'bat': bat,
    'heading': heading,
  };

  factory TelemetrySnapshot.fromJson(Map<String, dynamic> j) =>
      TelemetrySnapshot(
        timestamp: DateTime.parse(j['ts'] as String),
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        alt: (j['alt'] as num).toDouble(),
        speed: (j['speed'] as num).toDouble(),
        bat: (j['bat'] as num).toDouble(),
        heading: (j['heading'] as num).toDouble(),
      );
}

// Función auxiliar — distancia Haversine entre dos puntos en metros
double _haversine(LatLng a, LatLng b) {
  const R = 6371000.0;
  final lat1 = a.latitude * pi / 180;
  final lat2 = b.latitude * pi / 180;
  final dLat = (b.latitude - a.latitude) * pi / 180;
  final dLon = (b.longitude - a.longitude) * pi / 180;
  final s =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
  return R * 2 * atan2(sqrt(s), sqrt(1 - s));
}

// Sesión de vuelo completa — generada al aterrizar o al desconectar
class FlightSession {
  final DateTime startTime;
  final DateTime endTime;
  final List<TelemetrySnapshot> log;
  final String controlMode;
  final bool completed; // true = aterrizó normal, false = desconexión en vuelo
  final bool isSitl;

  FlightSession({
    required this.startTime,
    required this.endTime,
    required this.log,
    required this.controlMode,
    required this.completed,
    required this.isSitl,
  });

  Duration get duration => endTime.difference(startTime);

  // Trail de coordenadas válidas para el mapa (descarta (0,0))
  List<LatLng> get trail => log
      .map((s) => LatLng(s.lat, s.lon))
      .where((p) => p.latitude != 0.0 && p.longitude != 0.0)
      .toList();

  double get maxAlt => log.isEmpty ? 0 : log.map((s) => s.alt).reduce(max);
  double get maxSpeed => log.isEmpty ? 0 : log.map((s) => s.speed).reduce(max);
  double get minBat => log.isEmpty ? 0 : log.map((s) => s.bat).reduce(min);

  // Desnivel: diferencia entre la altitud máxima y la altitud de despegue
  double get altGain {
    if (log.isEmpty) return 0;
    return (maxAlt - log.first.alt).clamp(0, double.infinity);
  }

  // Distancia total recorrida sumando segmentos del trail
  double get totalDistanceM {
    final t = trail;
    if (t.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < t.length; i++) {
      d += _haversine(t[i - 1], t[i]);
    }
    return d;
  }

  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'controlMode': controlMode,
    'completed': completed,
    'log': log.map((s) => s.toJson()).toList(),
    'isSitl': isSitl,
  };

  factory FlightSession.fromJson(Map<String, dynamic> j) => FlightSession(
    startTime: DateTime.parse(j['startTime'] as String),
    endTime: DateTime.parse(j['endTime'] as String),
    controlMode: j['controlMode'] as String,
    completed: j['completed'] as bool,
    isSitl: j['isSitl'] as bool? ?? false,
    log: (j['log'] as List)
        .map((s) => TelemetrySnapshot.fromJson(s as Map<String, dynamic>))
        .toList(),
  );
}

// ─── FLIGHT PLAN MODELS ───────────────────────────────────────────────────────

enum WaypointActionType { none, hover, takePhoto, recordVideo, rtl, land }

class WaypointAction {
  final WaypointActionType type;
  final double seconds;

  const WaypointAction({
    this.type = WaypointActionType.none,
    this.seconds = 5.0,
  });

  WaypointAction copyWith({WaypointActionType? type, double? seconds}) =>
      WaypointAction(type: type ?? this.type, seconds: seconds ?? this.seconds);

  String get label {
    switch (type) {
      case WaypointActionType.none:
        return 'None';
      case WaypointActionType.hover:
        return 'Hover ${seconds.toInt()}s';
      case WaypointActionType.takePhoto:
        return 'Photo';
      case WaypointActionType.recordVideo:
        return 'Rec ${seconds.toInt()}s';
      case WaypointActionType.rtl:
        return 'RTL';
      case WaypointActionType.land:
        return 'Land';
    }
  }

  Map<String, dynamic> toJson() => {'type': type.name, 'seconds': seconds};

  factory WaypointAction.fromJson(Map<String, dynamic> j) => WaypointAction(
    type: WaypointActionType.values.firstWhere(
      (t) => t.name == (j['type'] as String? ?? 'none'),
      orElse: () => WaypointActionType.none,
    ),
    seconds: (j['seconds'] as num?)?.toDouble() ?? 5.0,
  );
}

class FlightWaypoint {
  final double lat;
  final double lon;
  final double altM;
  final WaypointAction action;

  const FlightWaypoint({
    required this.lat,
    required this.lon,
    this.altM = 10.0,
    this.action = const WaypointAction(),
  });

  FlightWaypoint copyWith({
    double? lat,
    double? lon,
    double? altM,
    WaypointAction? action,
  }) => FlightWaypoint(
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    altM: altM ?? this.altM,
    action: action ?? this.action,
  );

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'altM': altM,
    'action': action.toJson(),
  };

  factory FlightWaypoint.fromJson(Map<String, dynamic> j) => FlightWaypoint(
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    altM: (j['altM'] as num?)?.toDouble() ?? 10.0,
    action: WaypointAction.fromJson(
      (j['action'] as Map<String, dynamic>?) ?? {},
    ),
  );
}

class FlightPlan {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<FlightWaypoint> waypoints;

  FlightPlan({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.waypoints,
  });

  double get totalDistanceM {
    if (waypoints.length < 2) return 0;
    double d = 0;
    for (int i = 1; i < waypoints.length; i++) {
      d += _haversineWP(waypoints[i - 1], waypoints[i]);
    }
    return d;
  }

  static double _haversineWP(FlightWaypoint a, FlightWaypoint b) {
    const R = 6371000.0;
    final lat1 = a.lat * pi / 180;
    final lat2 = b.lat * pi / 180;
    final dLat = (b.lat - a.lat) * pi / 180;
    final dLon = (b.lon - a.lon) * pi / 180;
    final s =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(s), sqrt(1 - s));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'waypoints': waypoints.map((w) => w.toJson()).toList(),
  };

  factory FlightPlan.fromJson(Map<String, dynamic> j) => FlightPlan(
    id: j['id'] as String,
    name: j['name'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    waypoints: (j['waypoints'] as List)
        .map((w) => FlightWaypoint.fromJson(w as Map<String, dynamic>))
        .toList(),
  );
}

//------------------------PROVIDER PRINCIPAL----------------------------------
class DronProvider extends ChangeNotifier {
  final MqttLogic _mqtt = MqttLogic();
  final WebRTCLogic _webrtc = WebRTCLogic();

  //estados de conexión y vuelo
  bool isLoading = false;
  String message = 'Please connect to a drone';
  bool isConnected = false;
  bool isArmed = false;
  bool isFlying = false;
  bool _waitingForConnect = false;

  double takeoffAltitude = 7.0;
  double flightSpeed = 3.0;
  bool isConfigValid = true;

  ControlMode selectedMode = ControlMode.classic;

  DronProvider() {
    _loadFlightHistory();
    _loadFlightPlans();
  }

  void setControlMode(ControlMode mode) {
    selectedMode = mode;
    notifyListeners();
  }

  DroneConnectionMode droneConnectionMode = DroneConnectionMode.ardupilot;
  void setDroneConnectionMode(DroneConnectionMode mode) {
    if (isConnected) return; // no cambiar si ya conectado
    droneConnectionMode = mode;
    notifyListeners();
  }

  // Cámara activa: 0 = portátil, 1 = dron
  int cameraIndex = 1;

  // Nivel de zoom actual (1.0 a 5.0)
  double zoomLevel = 1.0;

  //---------- TELLO -------------
  double? telloTempC;
  int? telloWifi;
  int? telloFlightTime;

  bool isFollowMode = false;
  bool isOrbitMode = false;

  String followStatus = 'off';
  double tofDistance = -1.0;

  String orbitStatus = 'off';
  double orbitTofDistance = -1.0;

  // metodos

  void switchCamera() {
    cameraIndex = cameraIndex == 1 ? 0 : 1;
    _mqtt.publish(Constants.topicSetCamera, cameraIndex.toString());
    notifyListeners();
  }

  void setZoom(double value) {
    zoomLevel = value.clamp(1.0, 5.0);
    _mqtt.publish(Constants.topicSetZoom, zoomLevel.toStringAsFixed(1));
    notifyListeners();
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

  List<LatLng> droneTrail = [];

  //posicionamiento usuario
  LatLng? userPosition;
  double userAccuracy = 0;
  StreamSubscription<Position>? _locationSub;

  // WebRTC
  MediaStream? remoteStream;
  bool isVideoActive = false;

  // Grabación parada por defecto
  bool isRecording = false;

  // Para mostrar error de conexión en pantalla
  String? connectionErrorMode;

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

  // Lista de sesiones completadas (más reciente primero)
  final List<FlightSession> flightHistory = [];
  final List<FlightPlan> flightPlans = [];
  bool missionUploaded = false;
  bool isMissionMode = false;
  int activeMissionWaypoint = -1;
  String? currentMissionPlanId;
  List<TelemetrySnapshot> _sessionLog = [];
  DateTime? _sessionStart;
  bool _pendingMissionFlight = false;

  bool _connectingInProgress = false;
  Timer? _connectionTimeoutTimer;

  void setAltitude(String altValue) {
    final alt = double.tryParse(altValue.replaceAll(',', '.'));
    if (alt == null || alt < 2.0 || alt > 50.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    takeoffAltitude = alt;
    notifyListeners();
  }

  void setSpeed(String speedValue) {
    final speed = double.tryParse(speedValue.replaceAll(',', '.'));
    if (speed == null || speed < 1.0 || speed > 15.0) {
      isConfigValid = false;
      notifyListeners();
      return;
    }
    isConfigValid = true;
    flightSpeed = speed;
    if (isConnected) {
      _mqtt.publish(Constants.topicSpeed, flightSpeed.toString());
    }
    notifyListeners();
  }

  void updateJoystick({double? lx, double? ly, double? rx, double? ry}) {
    if (isFollowMode || isOrbitMode) return;
    if (lx != null) _lx = lx;
    if (ly != null) _ly = ly;
    if (rx != null) _rx = rx;
    if (ry != null) _ry = ry;
  }

  void _startJoystickTimer() {
    _joystickTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _webrtc.sendJoystick(_lx, _ly, _rx, _ry),
    );
  }

  void _stopJoystickTimer() {
    _joystickTimer?.cancel();
    _joystickTimer = null;
    _webrtc.sendJoystick(0, 0, 0, 0);
  }

  void _startSession() {
    if (_sessionStart != null) return;
    _sessionLog = [];
    _sessionStart = DateTime.now();
  }

  void _endSession({required bool completed}) {
    if (_sessionStart == null) return;
    if (_sessionLog.isEmpty) {
      _sessionStart = null;
      _sessionLog = [];
      return;
    }
    flightHistory.insert(
      0,
      FlightSession(
        startTime: _sessionStart!,
        endTime: DateTime.now(),
        log: List.unmodifiable(_sessionLog),
        controlMode: selectedMode.name,
        completed: completed,
        isSitl: droneConnectionMode == DroneConnectionMode.sitl,
      ),
    );
    if (flightHistory.length > 50) flightHistory.removeLast();
    _saveFlightHistory();
    _sessionLog = [];
    _sessionStart = null;
  }

  void _loadFlightHistory() {
    try {
      final stored = web.window.localStorage.getItem('ezdrone_flight_history');
      if (stored != null && stored.isNotEmpty) {
        final list = jsonDecode(stored) as List;
        flightHistory.clear();
        flightHistory.addAll(
          list.map((j) => FlightSession.fromJson(j as Map<String, dynamic>)),
        );
      }
    } catch (_) {}
  }

  void _saveFlightHistory() {
    try {
      web.window.localStorage.setItem(
        'ezdrone_flight_history',
        jsonEncode(flightHistory.map((s) => s.toJson()).toList()),
      );
    } catch (_) {}
  }

  void deleteFlightSession(int index) {
    if (index < 0 || index >= flightHistory.length) return;
    flightHistory.removeAt(index);
    _saveFlightHistory();
    notifyListeners();
  }

  void clearAllSessions() {
    flightHistory.clear();
    _saveFlightHistory();
    notifyListeners();
  }

  void _loadFlightPlans() {
    try {
      final stored = web.window.localStorage.getItem('ezdrone_flight_plans');
      if (stored != null && stored.isNotEmpty) {
        final list = jsonDecode(stored) as List;
        flightPlans.clear();
        flightPlans.addAll(
          list.map((j) => FlightPlan.fromJson(j as Map<String, dynamic>)),
        );
      }
    } catch (_) {}
  }

  void _saveFlightPlans() {
    try {
      web.window.localStorage.setItem(
        'ezdrone_flight_plans',
        jsonEncode(flightPlans.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}
  }

  void saveFlightPlan(FlightPlan plan) {
    final idx = flightPlans.indexWhere((p) => p.id == plan.id);
    if (idx >= 0) {
      flightPlans[idx] = plan;
    } else {
      flightPlans.insert(0, plan);
    }
    _saveFlightPlans();
    notifyListeners();
  }

  void deleteFlightPlan(String id) {
    flightPlans.removeWhere((p) => p.id == id);
    _saveFlightPlans();
    notifyListeners();
  }

  Future<void> uploadMission(FlightPlan plan) async {
    currentMissionPlanId = plan.id;
    if (!isConnected) return;
    final payload = jsonEncode({
      'planId': plan.id,
      'takeoffAlt': takeoffAltitude.toInt(),
      'speed': flightSpeed,
      'waypoints': plan.waypoints.map((w) => w.toJson()).toList(),
    });
    _mqtt.publish(Constants.topicUploadMission, payload);
    message = 'Mission ready — arm and press START';
    notifyListeners();
  }

  Future<void> startMission() async {
    if (!isConnected || !missionUploaded) return;
    _pendingMissionFlight = true;
    _mqtt.publish(Constants.topicSpeed, flightSpeed.toString());
    _mqtt.publish(Constants.topicStartMission, 'start');
    isMissionMode = true;
    message = 'Starting mission...';
    notifyListeners();

    Future.delayed(const Duration(seconds: 10), () {
      if (isMissionMode && !isFlying) {
        isMissionMode = false;
        message = 'Mission start timed out';
        notifyListeners();
      }
    });
  }

  void clearConnectionError() {
    connectionErrorMode = null;
  }

  // -----------------------CONECTAR----------------------------------
  Future<void> connectDron() async {
    // Guard síncrono: evita doble-tap antes de que el rebuild deshabilite el botón
    if (_connectingInProgress) return;
    _connectingInProgress = true;

    isLoading = true;
    _waitingForConnect =
        false; // reset por si se intenta conectar tras un fallo
    isFlying = false;
    message = 'Trying to connect...';
    notifyListeners();

    try {
      await _webrtc.disconnect();
    } catch (
      _
    ) {} // por si quedó una conexión WebRTC colgada de un intento previo

    try {
      await _mqtt.connect();
      _mqtt.subscribe(Constants.topicConnected);
      _mqtt.subscribe(Constants.topicArmed);
      _mqtt.subscribe(Constants.topicDisarmed);
      _mqtt.subscribe(Constants.topicFlying);
      _mqtt.subscribe(Constants.topicLanded);
      _mqtt.subscribe(Constants.topicDisconnected);
      _mqtt.subscribe(Constants.topicMissionUploaded);
      _mqtt.subscribe(Constants.topicMissionStarted);
      _mqtt.subscribe(Constants.topicMissionWaypoint);
      _mqtt.onMessageReceived = _handleMessage;

      // 1. Enviar modo ANTES del connect
      final modeStr = switch (droneConnectionMode) {
        DroneConnectionMode.ardupilot => 'ardupilot',
        DroneConnectionMode.sitl => 'sitl',
        DroneConnectionMode.tello => 'tello',
      };
      _mqtt.publish(Constants.topicSetMode, modeStr);

      // 2. Flush window: dejamos pasar los retained messages del broker
      //    (_waitingForConnect = false — serán ignorados en _handleMessage)
      await Future.delayed(const Duration(milliseconds: 500));

      // 3. A partir de aquí sí esperamos el topicConnected real
      //    Todos los modos (incluido Tello) esperan la confirmación MQTT.
      //    La ET publica topicConnected tanto para ArduPilot/SITL como para Tello.
      _waitingForConnect = true;

      // 4. Timeout de conexión: 20 s — timer cancelable
      _connectionTimeoutTimer?.cancel();
      _connectionTimeoutTimer = Timer(const Duration(seconds: 20), () {
        if (_waitingForConnect) {
          _waitingForConnect = false;
          _connectingInProgress = false;
          isLoading = false;
          message = 'Connection timeout — drone not responding';
          notifyListeners();
        }
      });

      // 5. Configurar cámara y enviar comando connect
      _mqtt.publish(Constants.topicSetCamera, cameraIndex.toString());
      _mqtt.publish(Constants.topicConnect, 'connect');

      // 6. Configurar callbacks WebRTC antes de conectar
      _webrtc.onRemoteStream = (stream) {
        remoteStream = stream;
        notifyListeners();
      };
      _webrtc.onTelemetry = (jsonStr) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleTelemetry(jsonStr);
        });
      };

      await _webrtc.connect(Constants.webrtcSignalUrl);

      // 7. Iniciar GPS cancelando suscripción previa si existía
      startUserLocation();
    } catch (error) {
      _connectionTimeoutTimer?.cancel();
      _waitingForConnect = false;
      _connectingInProgress = false;
      isLoading = false;
      message = '$error';
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

    _mqtt.publish(Constants.topicArm, 'arm');
    isLoading = false;
    notifyListeners();

    Timer(const Duration(seconds: 5), () {
      if (_waitingForArm && !_armConfirmed) {
        _waitingForArm = false;
        message = 'Not ready to arm';
        notifyListeners();
      }
    });
  }

  // -----------------------DESCONECTAR----------------------------------
  Future disconnectDron() async {
    _connectingInProgress = false;
    _connectionTimeoutTimer?.cancel();
    _waitingForConnect = false;
    if (!isConnected) return;

    isLoading = true;
    message = 'Disconnecting...';
    notifyListeners();

    _stopJoystickTimer();
    _locationSub?.cancel();
    _locationSub = null;

    // Desconectar WebRTC primero
    try {
      await _webrtc.disconnect();
    } catch (_) {}
    try {
      _mqtt.publish(Constants.topicDisconnect, 'disconnect');
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));

    // Limpiar estado LOCAL ahora, sin esperar confirmación de la ET
    _mqtt.disconnect();
    stopUserLocation();
    _endSession(completed: false);
    isConnected = false;
    isArmed = false;
    isFlying = false;
    isLoading = false;
    isVideoActive = false;
    isRecording = false;
    isFollowMode = false;
    isOrbitMode = false;
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
    cameraIndex = 1;
    zoomLevel = 1.0;
    missionUploaded = false;
    isMissionMode = false;
    activeMissionWaypoint = -1;
    currentMissionPlanId = null;
    message = 'Awaiting orders';
    notifyListeners();
  }

  // -----------------------DESPEGAR----------------------------------
  Future<void> takeOff() async {
    debugPrint(
      '[TAKEOFF] isConnected=$isConnected isArmed=$isArmed mode=$droneConnectionMode',
    );
    final needsArm = droneConnectionMode != DroneConnectionMode.tello;
    if (!isConnected || (needsArm && !isArmed)) {
      debugPrint('[TAKEOFF] BLOQUEADO');
      return;
    }
    debugPrint('[TAKEOFF] Publicando ${Constants.topicTakeoff}');
    isLoading = true;
    message = 'Taking off...';
    notifyListeners();
    final payload = '${takeoffAltitude.toInt()}:$flightSpeed';
    _mqtt.publish(Constants.topicTakeoff, payload);
    isLoading = false;
    notifyListeners();
  }

  // -----------------------ATERRIZAR----------------------------------
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

  // -----------------------RTL----------------------------------
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

  // -----------------------Swap entre mapa y vídeo----------------------------------
  void toggleVideo() {
    isVideoActive = !isVideoActive;
    notifyListeners();
  }

  // -----------------------MODO DETECCIÓN----------------------------------
  void setDetectionMode(DetectionMode mode) {
    detectionMode = mode;
    final modeStr = switch (mode) {
      DetectionMode.all => 'all',
      DetectionMode.person => 'person',
      DetectionMode.none => 'none',
    };
    _mqtt.publish(Constants.topicDetectionMode, modeStr);
    notifyListeners();
  }

  // -----------------------CAPTURA DE FOTO----------------------------------
  void capturePhoto() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _jsCapture('drone_capture_$ts.png');
    message = '!Photo saved!';
    notifyListeners();
  }

  // -----------------------GRABACIÓN DE VÍDEO----------------------------------
  void startRecording() {
    if (isRecording) return;
    _jsStartRecording();
    isRecording = true;
    message = 'Recording...';
    notifyListeners();
  }

  // -----------------------PARAR GRABACIÓN DE VÍDEO----------------------------------
  void stopRecording() {
    if (!isRecording) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _jsStopRecording('dronevideo$ts.mp4');
    isRecording = false;
    message = '!Video saved!';
    notifyListeners();
  }


  DateTime? _lastFlipTime;
  // -----------------------FLIP----------------------------------
  void sendFlip(String dir) {
    if (!isConnected || !isFlying) return;
    final now = DateTime.now();
    if (_lastFlipTime != null &&
        now.difference(_lastFlipTime!) < const Duration(seconds: 2)) {
      return;
    }
    _lastFlipTime = now;
    _mqtt.publish(Constants.topicFlip, dir);
  }

  // -----------------------MODO ORBIT----------------------------------
  void startOrbit({required int radiusCm, required bool clockwise}) {
    if (!isConnected || !isFlying || isOrbitMode) return;
    isOrbitMode = true;
    _stopJoystickTimer();
    final payload = '$radiusCm:${clockwise ? "cw" : "ccw"}';
    _mqtt.publish(Constants.topicOrbit, payload);
    notifyListeners();
  }

  // -----------------------PARAR MODO ORBIT----------------------------------
  void stopOrbit() {
    if (!isConnected || !isOrbitMode) return;
    isOrbitMode = false;
    if (isFlying) _mqtt.publish(Constants.topicOrbit, 'stop');
    _startJoystickTimer();
    notifyListeners();
  }

  // -----------------------MODO FOLLOW----------------------------------
  void toggleFollowMode() {
    if (!isConnected || !isFlying ) return;
    isFollowMode = !isFollowMode;
    if (isFollowMode) {
      _lx = 0.0;
      _ly = 0.0;
      _rx = 0.0;
      _ry = 0.0;
      _stopJoystickTimer();
    } else {
      _startJoystickTimer();
    }
    _mqtt.publish(Constants.topicFollowMode, isFollowMode ? 'true' : 'false');
    notifyListeners();
  }

  //void sendTelloCommand(String command) {
  //if (!isConnected || !isFlying) return;
  //_mqtt.publish(Constants.topicTelloCommand, command);
  //}

  // -----------------------HANDLER DE MENSAJES----------------------------------

  void _handleMessage(String topic, String payload) {

    // --------------- TOPIC CONNECTED ---------------
    if (topic == Constants.topicConnected) {
      if (!_waitingForConnect) return; // descarta retained/stale messages
      _connectionTimeoutTimer?.cancel(); // ← añadir
      _connectingInProgress = false;
      _waitingForConnect = false;
      isConnected = true;
      isLoading = false;
      message = 'Connection established!';
      notifyListeners();
      return;
    }

    // --------------- TOPIC ARMED ---------------
    if (topic == Constants.topicArmed) {
      if (!_waitingForArm && !isMissionMode) return;
      _armConfirmed = true;
      _waitingForArm = false;
      isArmed = true;
      message = 'BEWARE, MOTORS ARMED!!!';
      notifyListeners();
      return;
    }


    // --------------- TOPIC DISARMED ---------------
    if (topic == Constants.topicDisarmed) {
      isArmed = false;
      isFlying = false;
      _armConfirmed = false;
      _waitingForArm = false;
      isFollowMode = false;
      isOrbitMode = false;
      message = 'Motors disarmed automatically';
      notifyListeners();
      return;
    }

    // --------------- TOPIC FLYING ---------------
    if (topic == Constants.topicFlying) {
      isFlying = true;
      isMissionMode = missionUploaded;
      message = 'Flying';
      _startSession();
      if (!_pendingMissionFlight && !isMissionMode) _startJoystickTimer();
      _pendingMissionFlight = false;
      notifyListeners();
      return;
    }

    // --------------- TOPIC LANDED ---------------
    if (topic == Constants.topicLanded) {
      _endSession(completed: true);
      isFlying = false;
      isArmed = false;
      _armConfirmed = false;
      isMissionMode = false;
      missionUploaded = false;
      currentMissionPlanId = null;
      activeMissionWaypoint = -1;
      isOrbitMode = false;
      isFollowMode = false;
      message = 'Landed';
      notifyListeners();
      return;
    }

    // --------------- TOPIC MISSION UPLOADED ---------------
    if (topic == Constants.topicMissionUploaded) {
      missionUploaded = payload == 'ok';
      message = missionUploaded
          ? 'Mission ready — press START'
          : 'Mission upload failed';
      notifyListeners();
      return;
    }

    // --------------- TOPIC MISSION STARTED ---------------
    if (topic == Constants.topicMissionStarted) {
      if (payload == 'ok') {
        isMissionMode = true;
        isFlying = true;
        message = 'Mission started — AUTO mode active';
        _startSession();
      } else {
        isMissionMode = false;
        message = 'Mission failed to start';
      }
      notifyListeners();
      return;
    }

    // --------------- TOPIC MISSION WAYPOINT ---------------
    if (topic == Constants.topicMissionWaypoint) {
      activeMissionWaypoint = int.tryParse(payload) ?? 0;
      notifyListeners();
      return;
    }

    // --------------- TOPIC DISCONNECTED ---------------
    if (topic == Constants.topicDisconnected) {
      _endSession(completed: false);
      isConnected = false;
      isArmed = false;
      isFlying = false;
      isLoading = false;
      isVideoActive = false;
      isRecording = false;
      isFollowMode = false;
      isOrbitMode = false;
      _waitingForConnect = false;
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
      cameraIndex = 1;
      zoomLevel = 1.0;
      missionUploaded = false;
      isMissionMode = false;
      activeMissionWaypoint = -1;
      currentMissionPlanId = null;
      _connectingInProgress = false;
      _connectionTimeoutTimer?.cancel();
      _mqtt.disconnect();
      stopUserLocation();

      if (payload.startsWith('mode_unavailable')) {
        final mode = payload.split(':').last.toUpperCase();
        message = '$mode mode not available';
        connectionErrorMode = mode;
      } else if (payload == 'connection_failed') {
        message = 'Could not connect to drone. Check connection.';
        connectionErrorMode = null;
      } else {
        message = 'Awaiting orders';
        connectionErrorMode = null;
      }

      notifyListeners();
      return;
    }
  }

  // -----------------------HANDLER DE TELEMETRIA----------------------------------
  void _handleTelemetry(String jsonStr) {
    try {
      final status = jsonDecode(jsonStr) as Map<String, dynamic>;
      currentAlt = (status['alt'] as num?)?.toDouble() ?? currentAlt;
      currentBat =
          (status['battery_remaining'] as num?)?.toDouble() ?? currentBat;
      currentSpeed =
          (status['groundSpeed'] as num?)?.toDouble() ?? currentSpeed;
      currentHeading =
          (status['heading'] as num?)?.toDouble() ?? currentHeading;
      currentState = (status['state'] as String?) ?? currentState;
      currentMode = (status['flightMode'] as String?) ?? currentMode;
      currentLat = (status['lat'] as num?)?.toDouble() ?? currentLat;
      currentLon = (status['lon'] as num?)?.toDouble() ?? currentLon;
      currentVx = (status['vx'] as num?)?.toDouble() ?? currentVx;
      currentVy = (status['vy'] as num?)?.toDouble() ?? currentVy;

      if (currentLat != 0.0 && currentLon != 0.0) {
        droneTrail.add(LatLng(currentLat, currentLon));
        if (droneTrail.length > 100) droneTrail.removeAt(0);
      }
      if (isFlying && _sessionStart != null && currentLat != 0.0) {
        _sessionLog.add(
          TelemetrySnapshot(
            timestamp: DateTime.now(),
            lat: currentLat,
            lon: currentLon,
            alt: currentAlt,
            speed: currentSpeed,
            bat: currentBat,
            heading: currentHeading,
          ),
        );
      }
      followStatus = (status['followStatus'] as String?) ?? 'off';
      orbitStatus = (status['orbitStatus'] as String?) ?? 'off';
      final rawOrbitTof =
          (status['orbitTofDistance'] as num?)?.toDouble() ?? -1.0;
      orbitTofDistance = (rawOrbitTof > 0 && rawOrbitTof < 3000.0)
          ? rawOrbitTof
          : -1.0;
      final rawTof = (status['tofDistance'] as num?)?.toDouble() ?? -1.0;
      tofDistance = (rawTof > 0 && rawTof < 3000.0) ? rawTof : -1.0;
      notifyListeners();
    } catch (e) {
      debugPrint('[TELEMETRY] Parse error: $e');
    }
  }

  // Localización usuario
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
          if (userPosition != null && pos.accuracy > 50) {
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
