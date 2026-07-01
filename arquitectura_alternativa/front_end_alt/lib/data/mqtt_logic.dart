import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'dart:async';
import 'dart:math';

class MqttLogic {
  late MqttBrowserClient _client;
  bool _clientInitialized = false;

  // Suscripción al stream de updates: hay que guardarla para cancelarla en cada
  // reconexión y en disconnect(); si no, cada connect() acumula un listener que
  // puede emitir mensajes tardíos/duplicados al provider.
  StreamSubscription? _updatesSub;

  // Topics actualmente suscritos en el cliente vivo
  final List<String> _subscribedTopics = [];

  Function(String topic, String payload)? onMessageReceived;
  Function()? onDisconnected;

  Future<void> connect() async {
    // Cerrar cliente anterior limpiamente antes de crear uno nuevo
    if (_clientInitialized) {
      try { _client.disconnect(); } catch (_) {}
    }
    await _updatesSub?.cancel();
    _updatesSub = null;
    _subscribedTopics.clear();

    // Generar un clientId único para evitar conflictos en el broker
    final clientId = 'flutterAlt${Random().nextInt(9000)}';
    _client = MqttBrowserClient(
      'wss://broker.hivemq.com/mqtt',
      clientId,
    );
    // Configuraciones para conexiones WebSocket seguras
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

    // Escuchar mensajes entrantes y procesarlos con el callback registrado
    _updatesSub = _client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final payload = MqttPublishPayload.bytesToStringAsString(
          (msg.payload as MqttPublishMessage).payload.message,
        );
        onMessageReceived?.call(msg.topic, payload);
      }
    });
    // Marcar inicializado sólo cuando el listener ya está registrado.
    _clientInitialized = true;
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

  // Publica un mensaje en un topic específico.
  void publish(String topic, String payload) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  // Desconecta el cliente MQTT limpiamente, cancelando suscripciones y cerrando la conexión.
  void disconnect() {
    unsubscribeAll();
    _updatesSub?.cancel();
    _updatesSub = null;
    _client.disconnect();
    _clientInitialized = false;
  }
  
  void _onDisconnected() {
    onDisconnected?.call();
  }
}