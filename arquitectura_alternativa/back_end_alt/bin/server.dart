import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

void main() async {
  final handler = Pipeline()          //pipeline con middleware y un handler estático
      .addMiddleware(logRequests())
      .addHandler(_staticHandler);

  final server = await io.serve(handler, '0.0.0.0', 8080); //abre un server en el puerto 8080 que escucha a todo lo que esté en la misma red
  print('Server listening on port ${server.port}');
}

Future<Response> _staticHandler(Request request) async {    //handler que devuelve el index.html
  var path = request.url.path;
  if (path.isEmpty || path == '/') path = 'index.html';

  final file = File('web/$path');

  if (await file.exists()) {
    final bytes = await file.readAsBytes();
    return Response.ok(bytes, headers: {'Content-Type': _mimeType(path)});
  }

  // Flutter web routing: si no encuentra el archivo devuelve index.html
  final index = File('web/index.html');
  return Response.ok(
    await index.readAsBytes(),
    headers: {'Content-Type': 'text/html'},
  );
}

String _mimeType(String path) {     //le dice al navegador que tipo de archivo le está enviando
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.js'))   return 'application/javascript';
  if (path.endsWith('.css'))  return 'text/css';
  if (path.endsWith('.png'))  return 'image/png';
  if (path.endsWith('.ico'))  return 'image/x-icon';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.wasm')) return 'application/wasm';
  return 'application/octet-stream';
}
