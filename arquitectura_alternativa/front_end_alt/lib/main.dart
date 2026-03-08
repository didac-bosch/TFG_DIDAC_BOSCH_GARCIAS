import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'provider.dart';
import 'screens/setup_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DronProvider()),    //Provider
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,     //Para que no salga la línea roja de debug
        title: 'TFG Frontend',
        home: SetupScreen(),   //Pantalla inicio
      ),
    ),
  );
}
