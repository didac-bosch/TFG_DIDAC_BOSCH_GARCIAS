
import 'package:flutter/material.dart';

// Estilos y colores de la app.
// Están centralizados aquí para que todas las pantallas usen exactamente los
// mismos valores: cambiando este fichero cambia el aspecto de toda la app, y el
// rojo de peligro es literalmente el mismo rojo en todas partes.
class AppColors {

  //--------------COLORES----------------
  // Tema oscuro: fondo y superficies apagados para que la telemetría y el vídeo
  // destaquen, y un color por significado (verde OK, naranja aviso, rojo peligro).
  static const Color background    = Color(0xFF1E1E2E);
  static const Color surface       = Color(0xFF2A2A3E);
  static const Color primary       = Color(0xFF4CAF50);
  static const Color warning       = Color(0xFFFF9800);
  static const Color danger        = Color(0xFFC62828);
  static const Color textPrimary   = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0C0);
  static const Color disabled      = Color(0xFF555566);
  static const Color border        = Color(0xFF3A3A50);
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

  // tabularFigures fuerza que todas las cifras ocupen lo mismo: sin esto, un
  // valor de telemetría que cambia de dígito hace bailar el texto en pantalla.
  static const TextStyle instrument = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 19,
    fontWeight: FontWeight.bold,
    fontFeatures: [FontFeature.tabularFigures()],
    letterSpacing: 1,
  );

  static const TextStyle instrumentLabel = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 9,
    letterSpacing: 1.5,
    fontWeight: FontWeight.w600,
  );
}
