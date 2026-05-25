import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'dart:math';

class MqttLogic {
  late MqttBrowserClient _client;
  bool _clientInitialized = false;

  // Topics actualmente suscritos en el cliente vivo
  final List<String> _subscribedTopics = [];

  Function(String topic, String payload)? onMessageReceived;

  Future<void> connect() async {
    // Cerrar cliente anterior limpiamente antes de crear uno nuevo
    if (_clientInitialized) {
      try { _client.disconnect(); } catch (_) {}
    }
    _subscribedTopics.clear();

    final clientId = 'flutterAlt${Random().nextInt(9000)}';
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
    _clientInitialized = true;

    _client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final payload = MqttPublishPayload.bytesToStringAsString(
          (msg.payload as MqttPublishMessage).payload.message,
        );
        onMessageReceived?.call(msg.topic, payload);
      }
    });
  }

  // Suscribe a un topic. Ignora si ya está suscrito (evita duplicados).
  void subscribe(String topic) {
    if (_subscribedTopics.contains(topic)) return;
    _client.subscribe(topic, MqttQos.atLeastOnce);
    _subscribedTopics.add(topic);
  }

  // Cancela todas las suscripciones activas en el cliente actual.
  void unsubscribeAll() {
    for (final topic in List<String>.from(_subscribedTopics)) {
      try { _client.unsubscribe(topic); } catch (_) {}
    }
    _subscribedTopics.clear();
  }

  void publish(String topic, String payload) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void disconnect() {
    unsubscribeAll();
    _client.disconnect();
    _clientInitialized = false;
  }

  void _onDisconnected() {}
}