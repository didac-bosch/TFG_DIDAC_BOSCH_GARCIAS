import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'dart:convert';
import 'mqtt_logic.dart';

const String topicConnect    = 'mobileFlutter/groundStation/connect';      //tópicos mqtt para enviar a la estación tierra (origen/destino/accion)
const String topicArm        = 'mobileFlutter/groundStation/arm';
const String topicDisconnect = 'mobileFlutter/groundStation/disconnect';

Router buildRouter(MqttService mqtt) {     //constructor router
  final router = Router();

  Map<String, String> corsHeaders = {                           //mecanismo seguridad bloqueo peticiones http 
    'Access-Control-Allow-Origin': '*',     //permite peticiones desde cualquier origen 
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',     //lista de métodos http permitidos (IR AMPLIANDO!!!)
    'Access-Control-Allow-Headers': 'Content-Type',       //indica cabeceras que puede incluir el cliente en las peticiones 
    'Content-Type': 'application/json',       //indica que respuestas serán Json 
  };

  // POST /connect
  router.post('/connect', (Request request) async {
    print('HTTP POST /connect received');                   //log en consola
    mqtt.publish(topicConnect, 'connect');                  //mqtt publish
    return Response.ok(                                     //devuelve 200 (OK) y un Json de respuesta
      jsonEncode({'status': 'ok', 'message': 'Connect command sent'}),
      headers: corsHeaders,
    );
  });

  // POST /arm
  router.post('/arm', (Request request) async {
    print('HTTP POST /arm received');
    mqtt.publish(topicArm, 'arm');
    return Response.ok(
      jsonEncode({'status': 'ok', 'message': 'arm command sent'}),
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

  // GET /status                                          //devuelve estado de los booleanos (por ahora armed y connected)
  router.get('/status', (Request request) async {         //el frontend lo llama mediante el polling del Provider
    return Response.ok(                         
      jsonEncode({
        'armed':     mqtt.dronArmed,
        'connected': mqtt.dronConnected,
      }),
      headers: corsHeaders,
    );
  });

  // OPTIONS                      //preflight request para que el navegador no bloquee peticiones 
  router.add('OPTIONS', '/<path|.*>', (Request request) {
    return Response.ok('', headers: corsHeaders);
  });

  return router;
}
