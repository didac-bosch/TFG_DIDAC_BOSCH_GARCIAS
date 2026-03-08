import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:convert';

class MqttService {
  static const String _broker = 'broker.hivemq.com'; //intermediario
  static const int _port = 1883; //puerto estándard mqtt
  static const String _clientId = 'dart_backend_tfg'; //Id cliente

  late MqttServerClient _client; //Estados iniciales
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

  Future<void> connect() async {
    _client = MqttServerClient(_broker, _clientId);
    _client.port = _port;
    _client.logging(on: false);
    _client.keepAlivePeriod = 60; //si no recibe este ping se desconecta automáticamente

    _client.onDisconnected = () {
      isConnected = false;
      print('MQTT DISCONNECTED');
    };

    try {
      await _client.connect();
      isConnected = true;
      print('MQTT connected to broker: $_broker');

      _client.subscribe(
        'groundStation/mobileFlutter/#',
        MqttQos.atLeastOnce,
      ); //suscripción a tópicos groundStation/mobileFlutter/

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

        //otros topics
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
        if (topic == 'groundStation/mobileFlutter/disconnected') {
          dronArmed = false;
          dronConnected = false;
          dronFlying = false;

          //reset telemetría
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
