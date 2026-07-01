# Demo — Control por voz con wake word

Reconocimiento de voz en español con palabra de activación ("dron") y una
máquina de estados de escucha. Base del modo *Voice* de EZDrone.

## Qué demuestra

Flujo de escucha:
1. Pulsar el botón → escucha activa con timer de 10 s.
2. Cualquier voz detectada → resetea el timer.
3. 10 s de silencio → se apaga solo.
4. "dron" detectado → espera comando.
5. "dron" + comando → ejecuta al instante y queda encendido hasta parada manual.

### Máquina de estados (`ListenState`)

| Estado | Significado |
|---|---|
| `idle` | apagado |
| `waitingWakeWord` | escuchando, espera "dron" |
| `waitingCommand` | "dron" detectado, espera comando |
| `commandLocked` | comando ejecutado, escucha permanente |

### Comandos reconocidos

`armar` · `despegar` · `subir` · `bajar` · `mover derecha` · `mover izquierda` ·
`mover adelante` · `mover atrás` · `aterrizar` · `volver a despegue`

> **En esta demo no existe comando de voz "para"/"stop"**: el apagado es siempre
> manual (botón) o por el timer de auto-off. Es el set de esta demo
> (`_hasValidCommand`), no el de EZDrone (ver abajo).

## Librerías

| Paquete | Versión |
|---|---|
| `speech_to_text` | `^7.3.0` |

Puente con el motor nativo: iOS/macOS → Apple/Siri · Android → Google.

## Cómo ejecutar

```bash
flutter pub get
flutter run        # móvil real (necesita micrófono)
```

## Permisos

- **iOS** (`ios/Runner/Info.plist`): `NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`.
- **macOS**: igual que iOS + entitlements
  `com.apple.security.device.microphone` y `...audio-input`.
- **Android** (`AndroidManifest.xml`): `RECORD_AUDIO`, `INTERNET`,
  `BLUETOOTH`, `BLUETOOTH_ADMIN` + `<queries>` `RecognitionService` si
  `targetSdk >= 30`.

## Integración en EZDrone

Cada comando identificado se traduce a la acción MAVLink correspondiente y se
envía a la estación de tierra (arm/takeoff/goto/land/RTL).

### ⚠️ En EZDrone es distinto

EZDrone **no usa el paquete `speech_to_text`**. El modo *Voice*
(`lib/web_speech.dart` + `screens/voice_flight_screen.dart`) habla directamente con
la **Web Speech API nativa del navegador** (`SpeechRecognition`) vía JS interop:

| | Esta demo | EZDrone |
|---|---|---|
| Motor | `speech_to_text ^7.3.0` (Apple/Google nativo) | Web Speech API del navegador (JS interop) |
| Activación | wake word "dron" + máquina de estados | **push-to-talk** (mantener botón), sin wake word |
| Comando de parada | no hay ("para"/"stop" ausente) | **sí**: `para` |

Set de comandos de EZDrone: `armar` · `despegar` · `aterrizar` · `para` ·
`adelante` · `atrás` · `derecha` · `izquierda` · `subir` · `bajar` ·
`volver a despegue`. Esta demo aísla solo la *parte de reconocimiento* con un
paquete multiplataforma; EZDrone, al ser Web, va directo a la API del navegador.

## Notas

- `localeId: 'es_ES'`, `pauseFor: 4 s` (subido desde 2 s para no cortar entre
  palabras).
- En `onError`/`onStatus` el bucle de escucha se reinicia solo mientras el
  estado no sea `idle`.
