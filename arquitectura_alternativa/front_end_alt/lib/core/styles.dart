
import 'package:flutter/material.dart';

// Estilos y colores de la app
class AppColors {

  //--------------COLORES----------------
  static const Color background    = Color(0xFF1E1E2E);
  static const Color surface       = Color(0xFF2A2A3E);
  static const Color primary       = Color(0xFF4CAF50);  
  static const Color warning       = Color(0xFFFF9800);  
  static const Color danger        = Color(0xFFC62828);  
  static const Color textPrimary   = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0C0);
  static const Color disabled      = Color(0xFF555566);
}

class TextStyles {

  //--------------ESTILOS----------------
  static const TextStyle title = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.bold,
    letterSpacing: 2,
  );

  static const TextStyle status = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 16,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle button = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.2,
  );
}
