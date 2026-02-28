import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'data/mqtt_logic.dart';
import 'data/routes.dart';

void main() async {               //operaciones de red son asincronas y necesitan un await para esperar a que terminen antes de continuar
  final mqtt = MqttService();
  await mqtt.connect();       //inicio ante de crear rutas para evitar que http arranque antes del mqtt

  final router = buildRouter(mqtt);     //router 

  final handler = Pipeline()      //sistema pipeline con middleware para imprimir las peticiones recibidas 
      .addMiddleware(logRequests())
      .addHandler(router.call);    //petición http - logrequests - router - respuesta

  final server = await io.serve(handler, '0.0.0.0', 8080);  //vínculo al puerto 8080 y escucha a todos dispositivos conectados a la red
  print('Server listening in: ${server.port}');
}
