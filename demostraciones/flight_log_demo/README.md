# Demo — Flight Log (historial de vuelos)

Visor del historial de vuelos: lista de sesiones grabadas y, por sesión, mapa de
trayectoria, slider temporal para revivir el vuelo y descarga del log en CSV.
Base del *Flight Log Viewer* de EZDrone.

## Qué demuestra

- **Lista de sesiones** con métricas: duración, distancia, altitud máx,
  desnivel, velocidad máx, batería mín, modo de control y estado.
- **Detalle (bottom sheet)**:
  - Mapa satelital con la trayectoria (trail completo + tramo recorrido).
  - **Slider temporal**: arrastra para ver la posición y telemetría en cada
    instante; el icono del dron se orienta según el rumbo.
  - Estadísticas detalladas en tarjetas.
  - **DOWNLOAD CSV** (descarga real en Web).

### Columnas del CSV

```
timestamp, lat, lon, alt_m, speed_ms, bat_pct, heading_deg
```

## Estructura del código

| Fichero | Contenido |
|---|---|
| `main.dart` | arranque de la app |
| `flight_log_screen.dart` | toda la UI (lista, tarjetas, detail sheet, helpers) |
| `sample_flight_data.dart` | modelos `FlightLog`/`FlightSession` + 3 vuelos sintéticos |

Los 3 vuelos de ejemplo son sobre el campus EETAC: cuadrado 20 m (Classic+SITL),
triángulo 30 m (IMU) y vuelo parcial 15 m (Voice+SITL, interrumpido).

## Librerías

| Paquete | Versión | Uso |
|---|---|---|
| `flutter_map` | `^8.3.0` | mapa satelital |
| `latlong2` | `^0.9.1` | coordenadas |
| `web` | `^1.1.0` | descarga real del CSV en navegador |

## Cómo ejecutar

```bash
flutter pub get
flutter run -d chrome     # la descarga real solo funciona en Web
```

## Integración en EZDrone

`sampleSessions` equivale a `provider.flightHistory`, donde los datos se acumulan
en tiempo real durante el vuelo (un snapshot por segundo).

### ⚠️ En EZDrone es distinto

- **De dónde salen los datos**: esta demo usa 3 vuelos **sintéticos**
  (`sample_flight_data.dart`). EZDrone los guarda en **`localStorage`** del
  navegador y los alimenta con la **telemetría por WebRTC DataChannel (~5 Hz)**.
- **Puente de descarga**: esta demo descarga el CSV con `package:web` (`Blob`).
  EZDrone lo hace con un **puente JS propio `downloadCSVEZ`** en
  `lib/core/js_bridges.dart` (no en `fullscreen.dart`). Mismo resultado, distinta
  vía. Las columnas del CSV coinciden en ambos.
