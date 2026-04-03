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