import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'dart:math';

// ============================================================
// CAPA DE COMUNICACIÓN MQTT
//
// Wrapper sobre MqttBrowserClient para conectar al broker HiveMQ.
// Usa WebSocket seguro (wss, puerto 8884) porque la app corre en el navegador
// y una página HTTPS no puede abrir conexiones ws:// no seguras.
// Expone tres operaciones: connect, subscribe y publish. Los mensajes entrantes se entregan al
// provider mediante un callback (onMessageReceived).
// ============================================================

class MqttLogic {
  late MqttBrowserClient _client;

  Function(String topic, String payload)? onMessageReceived;

  Future<void> connect() async {
    final clientId =
        'flutterAlt${Random().nextInt(9000)}'; //ID única y aleatoria
    _client = MqttBrowserClient(
      'wss://broker.hivemq.com/mqtt',
      clientId,
    ); 
    _client.port = 8884; 
    _client.keepAlivePeriod = 20;
    _client.connectTimeoutPeriod = 10000;
    _client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
    _client.onDisconnected = _onDisconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();
    _client.connectionMessage = connMessage;

    await _client.connect();

    _client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      //listener que llama al callback cada vez que llega un mensaje
      for (final msg in messages) {
        final payload = MqttPublishPayload.bytesToStringAsString(
          (msg.payload as MqttPublishMessage).payload.message,
        );
        onMessageReceived?.call(msg.topic, payload);
      }
    });
  }

  void subscribe(String topic) {
    //escucha un topic
    _client.subscribe(topic, MqttQos.atLeastOnce);
  }

  void publish(String topic, String payload) {
    //envía un topic y su respectiva payload
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void disconnect() {
    _client.disconnect();
  }

  void _onDisconnected() {}
}
