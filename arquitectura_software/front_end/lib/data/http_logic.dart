import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'dart:convert';

class HttpLogic {
//PETICIONES HTTP

  ////// request para - Connect ////////
  Future<void> sendConnectRequest() async {
    return _sendPostRequest(Constants.endpointConnect);
  }

  ////// request para - Arm ////////
  Future<void> sendArmRequest() async {
    return _sendPostRequest(Constants.endpointArm);
  }

  ////// request para - Takeoff ////////
  Future<void> sendTakeoffRequest(double altitude) async {
    //en este caso se envía un body con la altitud predefinida
    try {
      final response = await http.post(
        Uri.parse(Constants.endpointTakeoff),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'altitude': altitude}),
      );
      if (response.statusCode != 200) {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }

    ////// request para - Speed ////////
  Future<void> sendSpeedRequest(double speed) async {
    try {
      final response = await http.post(
        Uri.parse(Constants.endpointSpeed),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'speed': speed}),
      );
      if (response.statusCode != 200) {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }


  ////// request para - Land ////////
  Future<void> sendLandRequest() async {
    return _sendPostRequest(Constants.endpointLand);
  }

  ////// request para - RTL ////////
  Future<void> sendRTLRequest() async {
    return _sendPostRequest(Constants.endpointRTL);
  }

  ////// request para - Move ////////
  Future<void> sendMoveRequest(String direction) async {
    try {
      final response = await http.post(
        Uri.parse(Constants.endpointMove),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'direction': direction}),
      );
      if (response.statusCode != 200) {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }


  ////// request para - Disconnect ////////
  Future<void> sendDisconnectRequest() async {
    return _sendPostRequest(Constants.endpointDisconnect);
  }



  // se hace un GET request a la URL de status y se devuelve un Map con los datos de estado del dron. Si hay error de conexión o el servidor devuelve un código distinto a 200, se lanza una excepción.
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final response = await http.get(
        Uri.parse(Constants.endpointStatus),
      ); //convierte URL a URI
      if (response.statusCode == 200) {
        //code 200 = ok
        return jsonDecode(response.body); //convierte el json a Map
      }
      throw Exception("Server error: ${response.statusCode}");
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }

  // se hace un POST request a la URL dada y se lanza una excepción si hay error de conexión o el servidor devuelve un código distinto a 200.
  Future<void> _sendPostRequest(String url) async {
    try {
      final response = await http.post(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception("Server error: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }
}
