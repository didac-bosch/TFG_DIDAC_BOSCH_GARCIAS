import 'dart:io';
import 'dart:convert';

// SERVIDOR HTTPS — SIRVE LA APP FLUTTER WEB + SEÑALIZACIÓN WEBRTC

// Registro de clientes WebSocket activos: peer_id - socket.
final Map<String, WebSocket> _clients = {};

// Configuración ICE enviada a cada peer al conectarse.
// Incluye STUN público y TURN privado en dronseetac.upc.edu.
final Map<String, dynamic> _iceConfig = {
  "type": "ice_config",
  "iceServers": [
    {"urls": "stun:stun.relay.metered.ca:80"},
    {
      "urls": "turn:dronseetac.upc.edu:3478",
      "username": "dronseetac",
      "credential": "Mimara00.",
    },
  ],
};

void main() async {
  // Carga el certificado TLS de Let's Encrypt para HTTPS
  final context = SecurityContext()
    ..useCertificateChain('/etc/letsencrypt/live/dronseetac.upc.edu/cert.pem')
    ..usePrivateKey('/etc/letsencrypt/live/dronseetac.upc.edu/privkey.pem');

  final server = await HttpServer.bindSecure('0.0.0.0', 8104, context);   //puerto 8104
  print('Server listening on https://dronseetac.upc.edu:8104');

  // Enruta cada petición: /ws  - WebSocket de señalización, resto - estáticos
  await for (final request in server) {
    if (request.uri.path == '/ws') {
      _handleWebSocket(request);
    } else {
      await _handleStatic(request);
    }
  }
}

// ------------- Signaling WebRTC --------------------
// Protocolo de tres pasos:
//   1. El cliente envía su peer_id como primer mensaje (string plano)
//   2. El servidor responde con la ICE config
//   3. Los mensajes siguientes (SDP / ICE) se reenvían al campo 'target'
Future<void> _handleWebSocket(HttpRequest request) async {
  try {
    final ws = await WebSocketTransformer.upgrade(request);
    String? peerId;

    print('[Signal] Cliente conectado, esperando peer_id...');

    ws.listen(
      (message) {
        // Primer mensaje: registro del peer_id
        if (peerId == null) {
          peerId = message as String;
          _clients[peerId!] = ws;
          print('[Signal] Peer conectado: $peerId');

          // Envía la ICE config inmediatamente tras el registro
          ws.add(jsonEncode(_iceConfig));
          print('[Signal] ICE config enviada a: $peerId');
          return;
        }

        // Mensajes siguientes: relay SDP / ICE candidates al peer destino
        try {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          final target = data['target'] as String?;
          if (target != null && _clients.containsKey(target)) {
            _clients[target]!.add(message);
          } else {
            print('[Signal] Target no encontrado: $target');
          }
        } catch (e) {
          print('[Signal] Error relay: $e');
        }
      },
      onDone: () {
        // Limpia el registro al desconectarse
        if (peerId != null) {
          _clients.remove(peerId);
          print('[Signal] Peer desconectado: $peerId');
        }
      },
      onError: (e) => print('[Signal] Error WS: $e'),
    );
  } catch (e) {
    print('[Signal] Error upgrade: $e');
    request.response.statusCode = HttpStatus.badRequest;
    await request.response.close();
  }
}

// -------------- Servidor de ficheros estáticos -----------------
// Sirve el build de Flutter Web desde la carpeta web/ del servidor.
Future<void> _handleStatic(HttpRequest request) async {
  var path = request.uri.path;
  if (path == '/' || path.isEmpty) path = '/index.html';

  // Sin caché para index y ficheros de bootstrap del service worker
  final noCache =
      path == '/index.html' ||
      path.contains('flutter_service_worker') ||
      path.contains('flutter_bootstrap') ||
      path.contains('version.json');

  if (noCache) {
    request.response.headers.set(
      'Cache-Control',
      'no-store, no-cache, must-revalidate',
    );
    request.response.headers.set('Pragma', 'no-cache');
  }

  final file = File('/root/didac/back_end_alt/web$path');
  if (await file.exists()) {
    request.response.headers.contentType = ContentType.parse(_mimeType(path));
    await request.response.addStream(file.openRead());
    await request.response.close();
    return;
  }

  // Fallback para Flutter web routing: rutas desconocidas devuelven index.html
  // para que el router de Flutter gestione la navegación en cliente
  final index = File('/root/didac/back_end_alt/web/index.html');
  request.response.headers.contentType = ContentType.html;
  request.response.headers.set(
    'Cache-Control',
    'no-store, no-cache, must-revalidate',
  );
  request.response.headers.set('Pragma', 'no-cache');
  await request.response.addStream(index.openRead());
  await request.response.close();
}

// Resuelve el Content-Type a partir de la extensión del fichero.
String _mimeType(String path) {
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.css')) return 'text/css';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.ico')) return 'image/x-icon';
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.wasm')) return 'application/wasm';
  return 'application/octet-stream';
}
