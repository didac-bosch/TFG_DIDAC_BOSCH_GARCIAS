# Demo — Joysticks virtuales

Dos joysticks virtuales estilo mando RC. Cada uno devuelve `(x, y)` en rango
`[-1.0, 1.0]` y vuelve a `(0, 0)` al soltar. Base del modo *Classic* de control
del dron en EZDrone.

## Qué demuestra

- **Joystick izquierdo** → Throttle (eje Y) y Yaw (eje X).
- **Joystick derecho** → Pitch (eje Y) y Roll (eje X).
- Lectura continua de los valores mientras se mantiene el stick movido.
- Visualización en tiempo real de los cuatro valores.

> El reparto de ejes es el de un mando RC. En EZDrone los valores `[-1, 1]` se
> multiplican por la velocidad máxima deseada para obtener m/s reales
> (`velocidad = ejeY * maxSpeed`).

## Librerías

| Paquete | Versión |
|---|---|
| `flutter_joystick` | `^0.2.2` |

## Cómo ejecutar

```bash
flutter pub get
flutter run -d chrome   # o cualquier dispositivo/emulador
```

No requiere permisos ni servicios externos.

## Integración en EZDrone

Los valores de los sticks se envían por **WebRTC DataChannel** a ~20 Hz hacia la
estación de tierra, que los traduce a `RC_override` (PWM `1500 + valor*500`).

> **Idéntico a EZDrone**: misma librería (`flutter_joystick ^0.2.2`) y mismo
> transporte (WebRTC DataChannel `joystick`, JSON `{lx, ly, rx, ry}`). Es la única
> demo cuya técnica no diverge de la app real.

## Notas

- `JoystickMode.all` permite todas las direcciones; se puede restringir con
  `JoystickMode.horizontal` / `vertical`.
- Base y stick decorables con `JoystickBaseDecoration()` y
  `JoystickStickDecoration()`.
