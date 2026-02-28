import 'package:flutter/material.dart';
import 'data/http_logic.dart';
import 'dart:async';

class DronProvider extends ChangeNotifier {          //notify Listeners() que ayudará a reconstruir todos los widfets que estén suscritos
  final HttpLogic _httpLogic = HttpLogic();


  //Estado inicial
  bool   isLoading   = false;
  String message     = "Please connect to a drone";
  bool   isConnected = false;
  bool   isArmed     = false;

  ///////////// CONNECT /////////////
  Future<void> connectDron() async {
    isLoading = true;                       //por si se complica la conexión entra en modo loading 
    message   = "Trying to connect...";
    notifyListeners();

    try {
      await _httpLogic.sendConnectRequest();        //petición de conexión
      isConnected = true;                           //si se ha podido connected = true
      message     = "Connection established!";
    } catch (error) {
      message = "$error";
    } finally {
      isLoading = false;                      //tanto si funciona como si no, loading = false y se notifica listeners para actualizar
      notifyListeners();
    }
  }

  ///////////// ARM /////////////
  Future<void> armDron() async {
    if (!isConnected) return;               //solo deja armar si está conectado, sino retorna null

    isLoading = true;
    message   = "Arming...";              //Arming porque puede ser que esté ready to arm o no.
    notifyListeners();

    try {
      await _httpLogic.sendArmRequest();      //Petición para armar
      startPolling();                         //Empiezan las consultas periódicas para saber el esetado en el que se encuentra en dron
    } catch (error) {
      message = "$error";
    } finally {
      isLoading = false;                      //Tanto si se ha podido o no, deja de cargar
      notifyListeners();
    }
  }

  ///////////// DISCONNECT /////////////
  Future<void> disconnectDron() async {
    if (!isConnected) return;                       //solo si está conectado 

    isLoading = true;
    message   = "Disconnecting...";
    notifyListeners();

    try {
      await _httpLogic.sendDisconnectRequest();         //petición de desconexión
      isConnected = false;
      isArmed     = false;
      message     = "Awaiting orders";
    } catch (error) {
      message = "$error";
    } finally {
      stopPolling();                        //al estar desconectado no necesita saber nada más
      isLoading = false;
      notifyListeners();
    }
  }

  ///////////// POLLING /////////////
  Timer? _statusTimer;

  void startPolling() {
    _statusTimer?.cancel();             //para evitar duplicados, cancela timers si se pulsa arm dos veces por ejemplo

    bool armConfirmed = false;
    final deadline    = DateTime.now().add(const Duration(seconds: 5));  //espera 5 segundos (arm tarda en activarse desde que se pulsa)

    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {         //mira cada dos segundos hasta que se cancele
      if (!isConnected) {
        stopPolling();
        return;
      }

      //cada dos segundos pregunta por el status del dron
      try {
        final status    = await _httpLogic.getStatus();
        final armed     = status['armed']     as bool;        //mira si está armado
        final connected = status['connected'] as bool;        //mira si está conectado 



        //posibilidades:

        //no conectado (y por tanto no armado)
        if (!connected) {
          isConnected = false;
          isArmed     = false;
          message     = "Awaiting orders";
          stopPolling();
          notifyListeners();
          return;
        }


        //armado pero no se ha confirmado que está armado (mission planner tarda en armar entonces
        //hasta que no se ha armado no se actualiza el código a armado!)
        if (armed && !armConfirmed) {
          armConfirmed = true;
          isArmed      = true;
          message      = "BEWARE, MOTORS ARMED";
          notifyListeners();
        }


        //arm confirmado pero en mission planner no está armado, significa que se acaban de desarmar automáticamente,
        //se desactiva el estado de armado en la web y sale que se han desarmado automáticamente!
        if (armConfirmed && !armed) {
          isArmed = false;
          message = "Motors disarmed automatically";
          stopPolling();
          notifyListeners();
          return;
        }


        //Cuando no deja armar y ha pasado la deadLine, significa que no está ready to arm!
        if (!armConfirmed && DateTime.now().isAfter(deadline)) {
          message = "Not ready to arm";
          stopPolling();
          notifyListeners();
          return;
        }

      } catch (_) {}
    });
  }

  void stopPolling() {
    _statusTimer?.cancel();
  }
}
