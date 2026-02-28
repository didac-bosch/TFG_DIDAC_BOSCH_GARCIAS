import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'dart:convert';

class HttpLogic {

  ////// request para - Connect ////////
  Future<void> sendConnectRequest() async {
    return _sendPostRequest(Constants.endpointConnect);
  }

  ////// request para - Arm ////////
  Future<void> sendArmRequest() async {
    return _sendPostRequest(Constants.endpointArm);
  }

  ////// request para - Disconnect ////////
  Future<void> sendDisconnectRequest() async {
    return _sendPostRequest(Constants.endpointDisconnect);
  }


  //get status.      (http.get)
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final response = await http.get(Uri.parse(Constants.endpointStatus));   //convierte URL a URI
      if (response.statusCode == 200) {       //code 200 = ok
        return jsonDecode(response.body);     //convierte el json a Map 
      }
      throw Exception("Server error: ${response.statusCode}");
    } catch (e) {
      throw Exception("Connection error: $e");
    }
  }


  //post request.     (http.post)
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
