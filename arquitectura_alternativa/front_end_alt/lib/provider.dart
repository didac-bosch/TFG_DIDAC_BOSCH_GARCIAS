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
external void _jsCapture(String id, String filename);

@JS('startDroneRecording')
external void _jsStartRecording();

@JS('stopDroneRecording')
external void _jsStopRecording(String id, String filename);

// Galería — almacenamiento de capturas/vídeos en IndexedDB
@JS('ezInitMediaStore')
external JSPromise<JSString> _jsInitMediaStore();

@JS('ezGetMediaUrl')
external String ezGetMediaUrl(String id);

@JS('ezDeleteMedia')
external void _jsDeleteMedia(String id);

// Modos de control
enum ControlMode { classic, voice, imu }

// Modos de detección YOLO — sincronizados con ET via MQTT
enum DetectionMode { all, person, none }

// Modos de conexión al dron
enum DroneConnectionMode { ardupilot, sitl, tello }

// ------ GALERÍA -------------------
// Metadata de una captura (foto o vídeo). El contenido real (blob) vive en
// IndexedDB; aquí solo se persiste la metadata en localStorage.
class MediaItem {
  final String id; // = millisecondsSinceEpoch como String
  final String type; // 'photo' | 'video'
  final String filename;
  final DateTime timestamp;
  final double? lat;
  final double? lon;
  final double? alt;

  MediaItem({
    required this.id,
    required this.type,
    required this.filename,
    required this.timestamp,
    this.lat,
    this.lon,
    this.alt,
  });

  bool get isPhoto => type == 'photo';
  bool get hasGps => lat != null && lon != null && (lat != 0.0 || lon != 0.0);

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'filename': filename,
    'ts': timestamp.toIso8601String(),
    'lat': lat,
    'lon': lon,
    'alt': alt,
  };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    type: j['type'] as String,
    filename: j['filename'] as String,
    timestamp: DateTime.parse(j['ts'] as String),
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    alt: (j['alt'] as num?)?.toDouble(),
  );
}

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
  // Refs (por id) a los MediaItem capturados durante este vuelo. La galería
  // sigue siendo la fuente de la verdad; aquí solo guardamos punteros.
  final List<String> mediaIds;

  FlightSession({
    required this.startTime,
    required this.endTime,
    required this.log,
    required this.controlMode,
    required this.completed,
    required this.isSitl,
    this.mediaIds = const [],
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
    'mediaIds': mediaIds,
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
    mediaIds:
        (j['mediaIds'] as List?)?.map((e) => e as String).toList() ?? const [],
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
  bool _altValid = true;
  bool _speedValid = true;
  bool get isConfigValid => _altValid && _speedValid;

  ControlMode selectedMode = ControlMode.classic;

  DronProvider() {
    _loadFlightHistory();
    _loadFlightPlans();
    _loadMediaGallery();
    _initMediaStore();
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

  // Posición/orientación interpoladas para el render fluido del marcador del
  // dron, independientes de la tasa de telemetría. Un timer hace lerp de estos
  // valores hacia el último dato recibido (currentLat/currentLon/currentHeading)
  // a 60 fps, de modo que el icono se desliza en lugar de saltar entre paquetes.
  final ValueNotifier<LatLng> droneRenderPos = ValueNotifier(const LatLng(0, 0));
  final ValueNotifier<double> droneRenderHeading = ValueNotifier(0.0);
  Timer? _interpTimer;
  LatLng _interpTarget = const LatLng(0, 0);
  double _interpTargetHeading = 0.0;

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
  // Esperando confirmación de aterrizaje tras pulsar LAND. Si la ET no confirma
  // (reafirma 'flying'), avisamos al usuario de que el dron sigue en el aire.
  bool _waitingForLand = false;

  //timer y valores del joystick
  Timer? _joystickTimer;
  double _lx = 0.0;
  double _ly = 0.0;
  double _rx = 0.0;
  double _ry = 0.0;

  // Lista de sesiones completadas (más reciente primero)
  final List<FlightSession> flightHistory = [];
  final List<FlightPlan> flightPlans = [];
  final List<MediaItem> mediaGallery = [];
  bool missionUploaded = false;
  bool isMissionMode = false;
  int activeMissionWaypoint = -1;
  String? currentMissionPlanId;
  List<TelemetrySnapshot> _sessionLog = [];
  DateTime? _sessionStart;
  // Ids de medios capturados durante la sesión activa (volcados al cerrarla)
  List<String> _sessionMediaIds = [];
  bool _pendingMissionFlight = false;

  bool _connectingInProgress = false;
  Timer? _connectionTimeoutTimer;
  // Auto-stop de la grabación iniciada por una acción recordVideo de la misión.
  Timer? _missionRecordTimer;

  void setAltitude(String altValue) {
    final alt = double.tryParse(altValue.replaceAll(',', '.'));
    if (alt == null || alt < 2.0 || alt > 50.0) {
      _altValid = false;
      notifyListeners();
      return;
    }
    _altValid = true;
    takeoffAltitude = alt;
    notifyListeners();
  }

  void setSpeed(String speedValue) {
    final speed = double.tryParse(speedValue.replaceAll(',', '.'));
    if (speed == null || speed < 1.0 || speed > 15.0) {
      _speedValid = false;
      notifyListeners();
      return;
    }
    _speedValid = true;
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

  // Parado de emergencia — neutraliza todos los ejes a 0. El timer (50 ms)
  // envía {0,0,0,0} de forma continua, dejando el dron en hover en el sitio.
  void emergencyStop() {
    _lx = 0;
    _ly = 0;
    _rx = 0;
    _ry = 0;
    message = 'STOP';
    notifyListeners();
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

  // Fija el nuevo objetivo de render (llamado en cada paquete de telemetría) y
  // arranca el timer de interpolación si hace falta.
  void _updateInterpTarget() {
    if (currentLat == 0.0 && currentLon == 0.0) return;
    _interpTarget = LatLng(currentLat, currentLon);
    _interpTargetHeading = currentHeading;
    // Primer dato válido: saltar directamente para no animar desde (0,0).
    final cur = droneRenderPos.value;
    if (cur.latitude == 0.0 && cur.longitude == 0.0) {
      droneRenderPos.value = _interpTarget;
      droneRenderHeading.value = _interpTargetHeading;
      return;
    }
    _startInterpTimer();
  }

  void _startInterpTimer() {
    if (_interpTimer != null) return;
    _interpTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      const t = 0.25; // factor de suavizado por frame
      final cur = droneRenderPos.value;
      final dLat = _interpTarget.latitude - cur.latitude;
      final dLon = _interpTarget.longitude - cur.longitude;
      // heading: interpolar por el camino angular más corto
      double dHdg = _interpTargetHeading - droneRenderHeading.value;
      while (dHdg > 180) {
        dHdg -= 360;
      }
      while (dHdg < -180) {
        dHdg += 360;
      }

      // Suficientemente cerca (~1 cm y 0.5°): fijar y parar para no gastar ciclos.
      if (dLat.abs() < 1e-7 && dLon.abs() < 1e-7 && dHdg.abs() < 0.5) {
        droneRenderPos.value = _interpTarget;
        droneRenderHeading.value = _interpTargetHeading;
        _stopInterpTimer();
        return;
      }
      droneRenderPos.value =
          LatLng(cur.latitude + dLat * t, cur.longitude + dLon * t);
      droneRenderHeading.value =
          (droneRenderHeading.value + dHdg * t) % 360;
    });
  }

  void _stopInterpTimer() {
    _interpTimer?.cancel();
    _interpTimer = null;
  }

  void _startSession() {
    if (_sessionStart != null) return;
    _sessionLog = [];
    _sessionMediaIds = [];
    _sessionStart = DateTime.now();
  }

  void _endSession({required bool completed}) {
    if (_sessionStart == null) return;
    if (_sessionLog.isEmpty) {
      _sessionStart = null;
      _sessionLog = [];
      _sessionMediaIds = [];
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
        mediaIds: List.from(_sessionMediaIds),
      ),
    );
    if (flightHistory.length > 50) flightHistory.removeLast();
    _saveFlightHistory();
    _sessionLog = [];
    _sessionMediaIds = [];
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

  void clearAllFlightPlans() {
    flightPlans.clear();
    _saveFlightPlans();
    notifyListeners();
  }

  // ----------------------- GALERÍA -----------------------------------------
  void _loadMediaGallery() {
    try {
      final stored = web.window.localStorage.getItem('ezdrone_media_gallery');
      if (stored != null && stored.isNotEmpty) {
        final list = jsonDecode(stored) as List;
        mediaGallery.clear();
        mediaGallery.addAll(
          list.map((j) => MediaItem.fromJson(j as Map<String, dynamic>)),
        );
      }
    } catch (_) {}
  }

  void _saveMediaGallery() {
    try {
      web.window.localStorage.setItem(
        'ezdrone_media_gallery',
        jsonEncode(mediaGallery.map((m) => m.toJson()).toList()),
      );
    } catch (_) {}
  }

  // Reconstruye los object URLs de los blobs guardados en IndexedDB.
  // Las URLs se regeneran en cada arranque (window._ezMediaUrls), por lo que
  // hay que avisar a la UI cuando estén listas.
  Future<void> _initMediaStore() async {
    try {
      await _jsInitMediaStore().toDart;
      notifyListeners();
    } catch (_) {}
  }

  void deleteMediaItem(String id) {
    _jsDeleteMedia(id);
    mediaGallery.removeWhere((m) => m.id == id);
    _saveMediaGallery();
    notifyListeners();
  }

  void clearMediaGallery() {
    for (final m in mediaGallery) {
      _jsDeleteMedia(m.id);
    }
    mediaGallery.clear();
    _saveMediaGallery();
    notifyListeners();
  }

  void _registerMedia(String id, String type, String filename) {
    mediaGallery.insert(
      0,
      MediaItem(
        id: id,
        type: type,
        filename: filename,
        timestamp: DateTime.now(),
        lat: isFlying ? currentLat : null,
        lon: isFlying ? currentLon : null,
        alt: isFlying ? currentAlt : null,
      ),
    );
    // Si se captura durante un vuelo loggeable (no Tello), enlazar a la sesión
    // activa para que también aparezca en el Flight Log de ese vuelo.
    if (isFlying &&
        _sessionStart != null &&
        droneConnectionMode != DroneConnectionMode.tello) {
      _sessionMediaIds.add(id);
    }
    _saveMediaGallery();
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
      _mqtt.subscribe(Constants.topicCameraAction);
      _mqtt.subscribe(Constants.topicFollowModeStatus);
      _mqtt.subscribe(Constants.topicOrbitStatus);
      _mqtt.onMessageReceived = _handleMessage;
      _mqtt.onDisconnected = _handleMqttDisconnected;

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
    _stopInterpTimer();
    droneRenderPos.value = const LatLng(0, 0);
    droneRenderHeading.value = 0.0;
    _interpTarget = const LatLng(0, 0);
    _interpTargetHeading = 0.0;
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
    _missionRecordTimer?.cancel();
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
    _waitingForLand = true;
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
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final filename = 'drone_capture_$id.png';
    _jsCapture(id, filename);
    _registerMedia(id, 'photo', filename);
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
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final filename = 'dronevideo$id.mp4';
    _jsStopRecording(id, filename);
    _registerMedia(id, 'video', filename);
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
  void startOrbit({required bool clockwise}) {
    if (!isConnected || !isFlying || isOrbitMode) return;
    isOrbitMode = true;
    // La ET reinicia Follow como Orbit; reflejarlo aquí para coherencia de UI.
    isFollowMode = false;
    _stopJoystickTimer();
    // Radio automático: la ET captura la distancia ToF actual a la persona.
    // El payload sólo lleva la dirección ("cw"/"ccw").
    final payload = clockwise ? 'cw' : 'ccw';
    _mqtt.publish(Constants.topicOrbit, payload);
    notifyListeners();
  }

  // -----------------------PARAR MODO ORBIT----------------------------------
  void stopOrbit() {
    if (!isConnected || !isOrbitMode) return;
    isOrbitMode = false;
    if (isFlying) _mqtt.publish(Constants.topicOrbit, 'stop');
    // Sólo reactivar el joystick si seguimos en vuelo y NO en follow: arrancarlo
    // en follow contradiría la semántica (el timer debe estar parado) y enviaría
    // comandos de joystick mientras el dron sigue a la persona.
    if (isFlying && !isFollowMode) _startJoystickTimer();
    notifyListeners();
  }

  // -----------------------MODO FOLLOW----------------------------------
  void toggleFollowMode() {
    if (!isConnected || !isFlying ) return;
    isFollowMode = !isFollowMode;
    if (isFollowMode) {
      // Si había una órbita activa, cerrarla: startOrbit() limpia isFollowMode al
      // entrar, pero la inversa no estaba implementada → la UI mostraba ambos
      // modos activos y un stopOrbit() posterior reactivaba el joystick.
      if (isOrbitMode) {
        isOrbitMode = false;
        _mqtt.publish(Constants.topicOrbit, 'stop');
      }
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

  void _handleMqttDisconnected() {
    if (!isConnected) return; // desconexión durante el intento de conexión — ya gestionada
    isConnected = false;
    // Limpieza completa: cancelar timers (joystick + interpolación), cerrar la
    // sesión de vuelo y resetear los flags de vuelo/modo. Antes sólo se cancelaba
    // _joystickTimer, dejando isFlying/isFollowMode/isOrbitMode y el timer de
    // interpolación activos sobre un canal ya muerto.
    _stopJoystickTimer();
    _stopInterpTimer();
    _endSession(completed: false);
    isFlying = false;
    isArmed = false;
    isLoading = false;
    isFollowMode = false;
    isOrbitMode = false;
    message = 'MQTT connection lost — commands unavailable';
    notifyListeners();
  }

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
      // Si estábamos esperando un aterrizaje y la ET reafirma 'flying', el
      // aterrizaje NO se confirmó: el dron sigue en el aire. Avisamos y
      // devolvemos el control (joystick) para que el usuario reintente LAND.
      final bool landFailed = _waitingForLand && isFlying;
      _waitingForLand = false;
      isFlying = true;
      isMissionMode = missionUploaded;
      message = landFailed ? 'Aterrizaje no confirmado, reintenta' : 'Flying';
      _startSession();
      if (!_pendingMissionFlight && !isMissionMode) _startJoystickTimer();
      _pendingMissionFlight = false;
      notifyListeners();
      return;
    }

    // --------------- TOPIC LANDED ---------------
    if (topic == Constants.topicLanded) {
      _endSession(completed: true);
      // Parar el joystick timer: si el aterrizaje lo inicia la ET (batería baja,
      // geofence, RTL) en vez del usuario, land() no se ejecuta y el timer
      // seguiría enviando comandos con el dron ya en tierra.
      _stopJoystickTimer();
      // Si una grabación de misión sigue activa al aterrizar (misión abortada
      // antes de cumplir los N s), la cerramos para no dejarla colgada.
      _missionRecordTimer?.cancel();
      if (isRecording) stopRecording();
      _waitingForLand = false;
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

    // --------------- TOPIC CAMERA ACTION (misión) ---------------
    // La ET pide capturar al alcanzar un waypoint con acción takePhoto/recordVideo.
    // Reutiliza el mismo mecanismo manual: capturePhoto / startRecording / stopRecording.
    if (topic == Constants.topicCameraAction) {
      if (payload == 'photo') {
        capturePhoto();
      } else if (payload.startsWith('record:')) {
        final secs = int.tryParse(payload.substring(7)) ?? 5;
        if (!isRecording) {
          startRecording();
          // La ET espera 'secs' en el waypoint; paramos la grabación al cumplirse.
          _missionRecordTimer?.cancel();
          _missionRecordTimer = Timer(Duration(seconds: secs), () {
            if (isRecording) stopRecording();
          });
        }
      }
      return;
    }

    // --------------- TOPIC FOLLOW MODE STATUS ---------------
    // Confirmación autoritativa de la ET: 'on' activó follow, 'off' rechazó o
    // desactivó. Si la ET rechaza (dron no volando, error), reseteamos el flag
    // optimista para que la UI no quede mostrando un modo que no arrancó.
    if (topic == Constants.topicFollowModeStatus) {
      final on = payload == 'on';
      if (on != isFollowMode) {
        isFollowMode = on;
        if (on) {
          _stopJoystickTimer();
        } else if (isFlying && !isOrbitMode) {
          _startJoystickTimer();
        }
        notifyListeners();
      }
      return;
    }

    // --------------- TOPIC ORBIT STATUS ---------------
    if (topic == Constants.topicOrbitStatus) {
      final on = payload == 'on';
      if (on != isOrbitMode) {
        isOrbitMode = on;
        if (on) {
          _stopJoystickTimer();
        } else if (isFlying && !isFollowMode) {
          _startJoystickTimer();
        }
        notifyListeners();
      }
      return;
    }

    // --------------- TOPIC DISCONNECTED ---------------
    if (topic == Constants.topicDisconnected) {
      _endSession(completed: false);
      // Parar timers antes de limpiar estado: si llega 'disconnected' durante un
      // vuelo activo (crash, pérdida de ET), ambos timers seguirían corriendo
      // sobre un canal WebRTC ya cerrado e interpolando posiciones congeladas.
      _stopJoystickTimer();
      _stopInterpTimer();
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

      if (payload == 'connection_failed') {
        message = 'Could not connect to drone. Check connection.';
      } else {
        message = 'Awaiting orders';
      }
      connectionErrorMode = null;

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
        if (droneTrail.length > 1000) droneTrail.removeAt(0);
      }
      // Actualiza el objetivo del marcador interpolado (render fluido).
      _updateInterpTarget();
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
      telloWifi = (status['telloWifi'] as num?)?.toInt() ?? telloWifi;
      telloTempC = (status['telloTempC'] as num?)?.toDouble() ?? telloTempC;
      telloFlightTime = (status['telloFlightTime'] as num?)?.toInt() ?? telloFlightTime;
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
