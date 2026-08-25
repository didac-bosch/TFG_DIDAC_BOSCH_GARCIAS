import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'dart:convert';
import 'mqtt_logic.dart';

// Tópicos MQTT para enviar comandos a la estación tierra (mobileFlutter/groundStation/<action>)
const String topicConnect =
    'mobileFlutter/groundStation/connect';
const String topicArm = 'mobileFlutter/groundStation/arm';
const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';
const String topicTakeoff = 'mobileFlutter/groundStation/takeoff';
const String topicLand = 'mobileFlutter/groundStation/land';
const String topicRTL = 'mobileFlutter/groundStation/rtl';
const String topicSpeed = 'mobileFlutter/groundStation/speed';
const String topicMove = 'mobileFlutter/groundStation/move'; 

// Función para construir el router con las rutas HTTP y la lógica MQTT
Router buildRouter(MqttService mqtt) {
  //constructor router
  final router = Router();

  // mecanismo CORS para permitir peticiones desde el frontend (obligatorio para que el navegador no bloquee las peticiones)
  Map<String, String> corsHeaders = {
    'Access-Control-Allow-Origin':
        '*', //permite peticiones desde cualquier origen
    'Access-Control-Allow-Methods':
        'GET, POST, OPTIONS', //lista de métodos http permitidos 
    'Access-Control-Allow-Headers':
        'Content-Type', //indica cabeceras que puede incluir el cliente en las peticiones
    'Content-Type': 'application/json', //indica que respuestas serán Json
  };

  // POST /connect
  router.post('/connect', (Request request) async {
    print('HTTP POST /connect received'); //log en consola
    mqtt.dronFlying = false;
    mqtt.dronArmed = false;
    mqtt.publish(topicConnect, 'connect'); //mqtt publish
    return Response.ok(
      //devuelve 200 (OK) y un Json de respuesta
      jsonEncode({'status': 'ok', 'message': 'Connect command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /arm
  router.post('/arm', (Request request) async {
    print('HTTP POST /arm received');
    mqtt.dronFlying = false;
    mqtt.publish(topicArm, 'arm');
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'arm command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /takeoff
  router.post('/takeoff', (Request request) async {
    print('HTTP POST /takeoff received');
    final body = await request
        .readAsString(); //lee el body de la request. - altitud takeoff
    final data = jsonDecode(body);
    final altitude = data['altitude'].toString();
    mqtt.publish(topicTakeoff, altitude); //publish del topic + altitud
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'takeoff command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /speed
  router.post('/speed', (Request request) async {   
    print('HTTP POST /speed received');
    final body = await request.readAsString();
    final data = jsonDecode(body);
    final speed = data['speed'].toString();
    mqtt.publish(topicSpeed, speed);
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'speed command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /land
  router.post('/land', (Request request) async {
    print('HTTP POST /land received');
    mqtt.publish(topicLand, 'land');
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'land command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /rtl
  router.post('/rtl', (Request request) async {
    print('HTTP POST /rtl received');
    mqtt.publish(topicRTL, 'rtl');
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'rtl command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /move
  router.post('/move', (Request request) async {
    print('HTTP POST /move received');
    final body = await request.readAsString(); //body = dirección
    final data = jsonDecode(body);
    final direction = data['direction'].toString();
    mqtt.publish(topicMove, direction); //envía topic + dirección
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'move command sent: $direction'}),
      headers: corsHeaders,
    );
  });

  // POST /disconnect
  router.post('/disconnect', (Request request) async {
    print('HTTP POST /disconnect received');
    mqtt.publish(topicDisconnect, 'disconnect');
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'disconnect command sent'}),
      headers: corsHeaders,
    );
  });

  // GET /status                                          //devuelve estado de los booleanos y la telemetría
  router.get('/status', (Request request) async {
    //el frontend lo llama mediante el polling del Provider
    return Response.ok(
      //toda la telemetría
      jsonEncode({
        'armed': mqtt.dronArmed,
        'connected': mqtt.dronConnected,
        'flying': mqtt.dronFlying,
        'alt': mqtt.telemetryAlt,
        'bat': mqtt.telemetryBat,
        'spd': mqtt.telemetrySpeed,
        'hdg': mqtt.telemetryHeading,
        'state': mqtt.telemetryState,
        'mode': mqtt.telemetryMode,
        'lat': mqtt.telemetryLat,
        'lon': mqtt.telemetryLon,
        'vx': mqtt.telemetryVx, 
        'vy': mqtt.telemetryVy, 
      }),
      headers: corsHeaders,
    );
  });

  // OPTIONS /<path> para manejar preflight requests de CORS (obligatorio para que el navegador no bloquee las peticiones)
  router.add('OPTIONS', '/<path|.*>', (Request request) {
    return Response.ok('', headers: corsHeaders);
  });

  return router;
}
