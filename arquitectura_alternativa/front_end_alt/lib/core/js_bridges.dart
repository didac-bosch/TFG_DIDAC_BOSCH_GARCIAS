//Puente con las funciones JavaScript declaradas en el index.html

import 'dart:js_interop';

@JS('requestFullscreenEZ')
external void requestFullscreenEZ();

@JS('exitFullscreenEZ')
external void exitFullscreenEZ();

@JS('lockOrientationEZ')
external void lockOrientationEZ(String orientation);

@JS('unlockOrientationEZ')
external void unlockOrientationEZ();

@JS('downloadCSVEZ')
external void downloadCSVEZ(String filename, String content);

// Registra en window._droneStream el primer <video> con pista de vídeo activa.
// Necesario para que la grabación (MediaRecorder) encuentre el stream del dron.
@JS('setDroneStreamRef')
external void setDroneStreamRef();