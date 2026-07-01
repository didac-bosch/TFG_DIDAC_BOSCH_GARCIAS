# Demo — Vídeo WebRTC + YOLO

Stream de vídeo en vivo desde una cámara (PC) hasta la app Flutter por **WebRTC**,
con detección de objetos **YOLOv5** y captura/grabación desde el cliente. Base
del vídeo en directo de EZDrone.

## Arquitectura

```
webrtc_video_sender.py  ──WebRTC (vídeo + YOLO)──►  Flutter (RTCVideoView)
   (cámara + YOLO)       ◄──WebSocket (comandos)──   detection_mode
```

- El **WebSocket** del handshake SDP queda abierto y sirve también de canal de
  control. SDP y comandos se distinguen por el campo `type`.
- El cliente solo envía `{"type":"detection_mode","mode":"all|person|none"}`.

## Qué demuestra

1. **Stream WebRTC** con detección YOLO en 3 modos: Todo / Solo personas / Ninguno.
2. **Captura de frame** → PNG descargado en el navegador.
3. **Grabación de vídeo** → WebM descargado en el navegador.

> **Captura y grabación ocurren 100 % en el cliente** (JS Interop:
> `captureDroneFrame`, `startDroneRecording`, `stopDroneRecording` definidas en
> `web/index.html`). El `webrtc_video_sender.py` también implementa captura/
> grabación *server-side* (PNG/mp4), pero **este cliente no las usa** — quedan
> como referencia.

## Librerías

**Flutter:** `flutter_webrtc ^1.3.1`, `web_socket_channel ^3.0.3`.
**Python (sender):** `torch`, `opencv-python`, `aiortc`, `av`, `websockets`.

## Cómo ejecutar

```bash
# 1. Arrancar el emisor (PC con cámara)
python webrtc_video_sender.py

# 2. App Flutter
flutter pub get
flutter run -d chrome
# Pulsar "Conectar"
```

### Configuración obligatoria

En `lib/video_screen.dart`, ajustar a tu red:
```dart
const String senderIP = '192.168.0.84';  // IP del PC que corre el sender
const int    senderPort = 9999;           // debe coincidir con el sender
```
La app y el sender deben estar en la misma red. El servidor STUN
(`stun.l.google.com:19302`) ya está configurado.

## Integración en EZDrone

Mismo patrón WebRTC; el sender corre en la estación de tierra capturando la
cámara del dron. El selector de detección equivale al `DetectionDropdown`.

### ⚠️ En EZDrone es distinto

- **Transporte del modo de detección**: esta demo envía `detection_mode` por el
  **WebSocket** de control (el mismo del handshake SDP). EZDrone lo envía por
  **MQTT** (topic `topicDetectionMode`), porque WSS+MQTT ya es el canal de comandos
  discretos de la app. El vídeo en sí sí va por WebRTC en ambos.
- **Versión**: la demo fija `flutter_webrtc ^1.3.1`; EZDrone usa `^1.4.0`.
