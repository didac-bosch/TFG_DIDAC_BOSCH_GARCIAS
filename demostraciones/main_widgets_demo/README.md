# Demo — Widgets y botones de EZDrone

Catálogo interactivo de los **10 tipos de widget/botón** usados en EZDrone,
agrupados por categoría, cada uno con una nota técnica de dónde se usa y cómo se
comporta. Útil como referencia de UI para futuros desarrolladores.

## Widgets demostrados

| # | Widget | Dónde se usa en EZDrone |
|---|---|---|
| 1 | `ElevatedButton.icon` | acciones principales: CONNECT, ARM, TAKEOFF, LAND, RTL, DISCONNECT |
| 2 | `GestureDetector` + `AnimatedContainer` | botón táctico con borde (HudButton, FlipBtn, ModeOption) |
| 3 | `GestureDetector` + `Container` | botón icono compacto (captura, grabar, swap cámara) |
| 4 | `GestureDetector` (longPress + tapDown) | presión continua de altitud (IMU) |
| 5 | `Slider` | zoom de cámara (rango 1.0–5.0) |
| 6 | `DropdownButton` | selector de modo de detección YOLO |
| 7 | `ModeChip` / `ConnectionChip` | selector exclusivo (Classic/Voice/IMU, ArduPilot/SITL/Tello) |
| 8 | `ModalBottomSheet` + `DraggableScrollableSheet` | hoja de ayuda arrastrable |
| 9 | `AlertDialog` | confirmación (borrar waypoints, error de conexión) |
| 10 | `ReorderableListView` | listas reordenables (waypoints, registros) |

El estado de cada widget interactivo es real (`setState`), de modo que reflejan
las transiciones tal como en la app (p.ej. ARM→TAKEOFF→LAND habilitan/
deshabilitan botones en cadena).

## Paleta (`AppColors`)

| Color | Hex | Uso |
|---|---|---|
| `background` | `#1E1E2E` | fondo general |
| `surface` | `#2A2A3E` | tarjetas y barras |
| `primary` | `#4CAF50` | verde (conectado, TAKEOFF) |
| `warning` | `#FF9800` | naranja (ARM, LAND, RTL) |
| `danger` | `#C62828` | rojo (armado, DISCONNECT) |
| `textPrimary` | `#FFFFFF` | |
| `textSecondary` | `#B0B0C0` | |
| `disabled` | `#555566` | |

## Cómo ejecutar

```bash
flutter pub get
flutter run -d chrome
```

No requiere permisos ni servicios externos: todo es UI con estado local.

## Notas

- Los widgets `_HudButton`, `_IconCompactButton`, `_AltButton`, `_ModeChip`,
  etc. son réplicas de los de EZDrone para poder copiarlos directamente.
- Botones 8 (SHOW HELP SHEET) y 9 (SHOW ALERT DIALOG) abren ejemplos completos
  de las hojas y diálogos reales.

> **Alcance**: esta demo cataloga los **controles interactivos** (botones, chips,
> slider, sheets). EZDrone tiene además **widgets de telemetría** propios que esta
> demo **no** incluye —`StatusBanner`, `BatteryGauge`, `InstrumentTile`,
> `CompactTelemetryRow` en `lib/widgets/telemetry_widgets.dart`— porque solo muestran
> datos, no reciben interacción.
