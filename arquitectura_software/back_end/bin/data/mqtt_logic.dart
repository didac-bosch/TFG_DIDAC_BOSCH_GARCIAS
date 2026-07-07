import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:convert';

// Clase para manejar la conexión MQTT y la lógica de suscripción/publicación
class MqttService {
  static const String _broker = 'broker.hivemq.com'; //intermediario
  static const int _port = 1883; //puerto estándard mqtt
  static const String _clientId = 'dart_backend_tfg'; //Id cliente

// variables de estado (late para inicializar después de la conexión)
  late MqttServerClient _client; 
  bool isConnected = false;
  bool dronArmed = false;
  bool dronConnected = false;
  bool dronFlying = false;

  // Variables telemetría
  double telemetryAlt = 0.0;
  double telemetryBat = 0.0;
  double telemetrySpeed = 0.0;
  double telemetryHeading = 0.0;
  String telemetryState = "Unknown";
  String telemetryMode = "Unknown";
  double telemetryLat = 0.0;
  double telemetryLon = 0.0;
  double telemetryVx = 0.0;
  double telemetryVy = 0.0;

  // Método para conectar al broker MQTT
  Future<void> connect() async {
    _client = MqttServerClient(_broker, _clientId);
    _client.port = _port;
    _client.logging(on: false);
    _client.keepAlivePeriod = 60; // keepalive period, si en 60 segundos no hay comunicación, se considera desconectado

    _client.onDisconnected = () {
      isConnected = false;
      print('MQTT DISCONNECTED');
    };

    // Intentamos conectar al broker
    try {
      await _client.connect();
      isConnected = true;
      print('MQTT connected to broker: $_broker');

      // Suscribirse a los topics de groundStation/mobileFlutter/
      _client.subscribe(
        'groundStation/mobileFlutter/#',
        MqttQos.atLeastOnce,
      ); 

      // Escuchar los mensajes entrantes
      _client.updates!.listen((
        List<MqttReceivedMessage<MqttMessage>> messages,
      ) {
        //emite eventos cuando llega un mensaje en los tópicos suscritos
        final topic = messages[0].topic;
        final payload = MqttPublishPayload.bytesToStringAsString(
          (messages[0].payload as MqttPublishMessage).payload.message,
        );

        // No imprimimos todos los payload para no saturar con la telemetría
        if (topic != 'groundStation/mobileFlutter/telemetry') {
          print('MQTT received - Topic: $topic | Payload: $payload');
        }

        //actualización de estado por tópicos. (broker solo entrega uno a la vez, por eso no son ifelse)

        // topics de telemetría, se actualizan las variables de telemetría según el topic recibido
        if (topic == 'groundStation/mobileFlutter/telemetry') {
          try {
            //si se envía telemetría se decodifica si se puede
            final data = jsonDecode(payload);
            telemetryAlt = (data['alt'] ?? 0.0).toDouble();
            telemetryBat = (data['battery_remaining'] ?? 0.0).toDouble();
            telemetrySpeed = (data['groundSpeed'] ?? 0.0).toDouble();
            telemetryHeading = (data['heading'] ?? 0.0).toDouble();
            telemetryState = data['state'] ?? "Unknown";
            telemetryMode = data['flightMode'] ?? "Unknown";
            telemetryLat = (data['lat'] ?? 0.0).toDouble();
            telemetryLon = (data['lon'] ?? 0.0).toDouble();
            telemetryVx = (data['vx'] ?? 0.0).toDouble(); 
            telemetryVy = (data['vy'] ?? 0.0).toDouble(); 
          } catch (e) {
            print("Error parsing telemetry: $e");
          }
        }

        // topics de estado del dron, se actualizan las variables de estado según el topic recibido
        if (topic == 'groundStation/mobileFlutter/connected') {
          dronConnected = true;
          print('dron connected detected in backend');
        }
        if (topic == 'groundStation/mobileFlutter/armed') {
          dronArmed = true;
          print('dron armed detected in backend');
        }
        if (topic == 'groundStation/mobileFlutter/disarmed') {
          dronArmed = false;
          print('dron disarmed detected in backend');
        }
        if (topic == 'groundStation/mobileFlutter/flying') {
          dronFlying = true;
          print('dron flying detected in backend');
        }
        if (topic == 'groundStation/mobileFlutter/landed') {
          dronFlying = false;
          dronArmed = false;
          print('dron landed detected in backend');
        }

        // topic disconnect, se resetea todo
        if (topic == 'groundStation/mobileFlutter/disconnected') {
          dronArmed = false;
          dronConnected = false;
          dronFlying = false;

          telemetryAlt = 0.0;
          telemetryBat = 0.0;
          telemetrySpeed = 0.0;
          telemetryHeading = 0.0;
          telemetryState = "Unknown";
          telemetryMode = "Unknown";

          print('dron disconnected detected in backend');
        }
      });
    } catch (e) {
      print('Error connecting MQTT: $e');
      _client.disconnect();
    }
  }

  // publish para enviar mensajes al broker
  void publish(String topic, String payload) {
    if (!isConnected) {
      print('Not able to publish, MQTT not connected.');
      return;
    }
    final builder = MqttClientPayloadBuilder(); //constructor de payloads
    builder.addString(payload); //añade la string de la payload convertida
    _client.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
    ); //envía mensaje al broker
    print('MQTT published -  Topic: $topic | Payload: $payload');
  }
}
