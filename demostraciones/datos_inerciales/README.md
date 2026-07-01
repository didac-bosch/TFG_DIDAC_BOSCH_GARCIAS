# Demo — Datos inerciales (IMU)

Lee los tres ángulos de orientación del móvil (pitch, roll, yaw) usando la API
`DeviceOrientationEvent` del navegador y los muestra a ~20 Hz. Base del modo
*IMU* de control del dron (inclinar el móvil = mover el dron).

## Qué demuestra

- **PITCH** (beta): inclinación adelante/atrás — `[-180°, 180°]`
- **ROLL** (gamma): inclinación izquierda/derecha — `[-90°, 90°]`
- **YAW** (alpha): rotación horizontal — `[0°, 360°]`

Los valores ya vienen fusionados por el navegador (acelerómetro + giroscopio +
magnetómetro). Flutter los lee por *polling* con un `Timer` a 20 Hz.

## Cómo funciona (puente JS)

El móvil expone los sensores vía JavaScript en `web/index.html`
(`requestMotionPermission`, `getAlpha/Beta/Gamma`, `stopOrientation`). El código
Dart los invoca con `dart:js_interop`. **No usa el paquete `sensors_plus`**
declarado en `pubspec.yaml` (queda como dependencia vestigial; el control real
es vía navegador).

## Cómo ejecutar (requiere HTTPS)

`DeviceOrientationEvent` exige **HTTPS**. En producción (EZDrone con HTTPS)
funciona directo. En local, usar un túnel:

```bash
# 1. ngrok (solo la primera vez)
brew install ngrok
ngrok config add-authtoken <TU_TOKEN>

# 2. servir Flutter
flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0

# 3. túnel HTTPS (otra terminal)
ngrok http 8080
# → abrir la URL https://xxxx.ngrok.io en Safari (iOS) / Chrome (Android)
```

En iOS hay que pulsar **ACTIVAR SENSORES** para conceder el permiso
(`DeviceOrientationEvent.requestPermission`). Android + Chrome no lo necesita.

> Cada sesión gratuita de ngrok dura ~2 h; al expirar, repetir pasos 2-3.

## Integración en EZDrone

- Mapear pitch/roll a PWM: `1500 + valor_normalizado * 500`.
- Enviar por **WebRTC DataChannel** a ~20 Hz (el `Timer` ya corre a esa
  frecuencia, solo añadir el `send`).
- Sustituye al joystick derecho en el modo IMU.

> **Mismo puente** que EZDrone (`DeviceOrientationEvent` vía JS interop). La
> diferencia es solo el mapeo: esta demo enseña los **ángulos crudos**, mientras que
> EZDrone (`screens/imu_flight_screen.dart`) aplica **dos modos** — *normal*
> (beta→pitch, gamma→roll) y *volante* (invierte beta/gamma con neutro en −50°). El
> ángulo `alpha` (yaw) no se mapea a control en ninguno.
