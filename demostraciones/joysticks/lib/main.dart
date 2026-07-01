import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';

// ============================================================
// DEMO: JOYSTICK VIRTUAL CON FLUTTER
// ============================================================
//
// Esta app demuestra el uso de la librería flutter_joystick
// para implementar dos joysticks virtuales estilo mando RC.
//
// LIBRERÍA: flutter_joystick: ^0.2.2
//
// FUNCIONAMIENTO:
//   - Cada joystick devuelve valores X e Y en rango [-1.0, 1.0]
//   - X: -1.0 (izquierda) - +1.0 (derecha)
//   - Y: -1.0 (arriba)    - +1.0 (abajo) 
//   - Al soltar el joystick vuelve automáticamente a (0.0, 0.0)
//   - El listener se llama continuamente mientras está movido
//   - JoystickMode.all permite movimiento en todas las direcciones, pero también hay opciones para restringir a horizontal o vertical.
//
// JOYSTICK IZQUIERDO  - Throttle (Y) y Yaw (X). (En el caso del mando RC, sino se pueden atribuir valores al gusto)
// JOYSTICK DERECHO    - Pitch (Y) y Roll (X)
//
// USO EN EL DRON:
//   Los valores [-1.0, 1.0] se multiplicarían por la velocidad
//   máxima deseada para obtener m/s reales. Ejemplo:
//   double speed = joystickY * maxSpeed;
//
// DECORACIÓN JOYSTICKS
//   Con JoystickBaseDecoration() - Decoración de la base 
//   Con JoystickStickDecoration() - Decoración del stick
// ============================================================


void main() {
  runApp(const MaterialApp(
    home: JoystickDemo(),
  ));
}

class JoystickDemo extends StatefulWidget {
  const JoystickDemo({super.key});

  @override
  State<JoystickDemo> createState() => _JoystickDemoState();
}

class _JoystickDemoState extends State<JoystickDemo> { 
  //clase de estado para actualizar los valores de los joysticks en tiempo real

  //VARIABLES DE ESTADO (VALORES DE LOS JOYSTICKS)

  // Valores joystick izquierdo
  double _leftX = 0.0;   // rotación
  double _leftY = 0.0;   // altitud

  // Valores joystick derecho
  double _rightX = 0.0;  // izquierda/derecha
  double _rightY = 0.0;  // adelante/atrás

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [

          // VALORES EN TIEMPO REAL
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3E),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Valores izquierdo
                Column(
                  children: [
                    const Text('LEFT', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 8),
                    Text(
                      'X: ${_leftX.toStringAsFixed(2)}', // Valor del joystick izquierdo (rotación)
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Y: ${_leftY.toStringAsFixed(2)}',  // Valor del joystick izquierdo (altitud)
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                // Separador
                Container(width: 1, height: 60, color: Colors.white24),
                // Valores derecho
                Column(
                  children: [
                    const Text('RIGHT', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 8),
                    Text(
                      'X: ${_rightX.toStringAsFixed(2)}', // Valor del joystick derecho (izquierda/derecha)
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Y: ${_rightY.toStringAsFixed(2)}', // Valor del joystick derecho (adelante/atrás)
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 48),


          // JOYSTICKS
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // JOYSTICK IZQUIERDO
              Column(
                children: [
                  const Text('THROTTLE / YAW',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 12),
                  Joystick(
                    mode: JoystickMode.all,     //JoystickMode.all permite movimiento en todas las direcciones


                    listener: (details) {       //callback con los valores
                      setState(() {
                        _leftX = details.x;  // -1.0 a 1.0
                        _leftY = details.y;  // -1.0 a 1.0
                      });
                    },
                  ),
                ],
              ),


              // JOYSTICK DERECHO
              Column(
                children: [
                  const Text('PITCH / ROLL',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 12),
                  Joystick(
                    mode: JoystickMode.all,

      
                    listener: (details) {
                      setState(() {
                        _rightX = details.x;
                        _rightY = details.y;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
