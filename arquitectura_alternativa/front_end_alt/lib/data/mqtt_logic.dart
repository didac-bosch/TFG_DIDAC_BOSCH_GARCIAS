import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'dart:math';
//usa mqqt_browser en lugar de mqtt_server, porque corre en el navegador.
//al correr en el navegador, necesita webSockets ya que no se permite TCP directo

class MqttLogic {
  late MqttBrowserClient _client;
  Function(String topic, String payload)? onMessageReceived;


  Future<void> connect() async {
    final clientId = 'flutterAlt${Random().nextInt(9000)}'; //ID única y aleatoria
    _client = MqttBrowserClient('ws://broker.hivemq.com/mqtt', clientId);
    _client.port = 8000;  // puerto WebSocket de HiveMQ (no el 1883 de TCP)
    _client.keepAlivePeriod = 20; // ping cada 20s para mantener la conexión viva y que el broker no la cierre
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


  void subscribe(String topic) {  //escucha un topic
    _client.subscribe(topic, MqttQos.atLeastOnce);
  }


  void publish(String topic, String payload) {    //envía un topic y su respectiva payload
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }


  void disconnect() {
    _client.disconnect();
  }


  void _onDisconnected() {}
}
