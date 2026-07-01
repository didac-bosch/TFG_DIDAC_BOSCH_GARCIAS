# Demo — Flight Plan (misiones con waypoints)

Editor de planes de vuelo: se tocan puntos sobre un mapa satelital para crear
waypoints numerados, se configuran y se exportan como JSON listo para la
estación de tierra. Base del editor de misiones de EZDrone.

## Qué demuestra

1. Tocar el mapa coloca waypoints numerados.
2. Tocar un marcador abre un diálogo para editar:
   - Altitud (2–120 m)
   - Acción al llegar: `none` / `hover` / `photo` / `record` / `RTL` / `land`
   - Duración (para `hover` y `record`)
3. Waypoints reordenables con drag & drop.
4. **DOWNLOAD JSON** descarga el plan completo (descarga real en Web).
5. Overlay con número de WP y distancia total de la ruta (Haversine).

### Acciones por waypoint

| Acción | Efecto |
|---|---|
| `none` | pasa al siguiente sin parar |
| `hover` | mantiene posición N s |
| `takePhoto` | dispara cámara |
| `recordVideo` | graba N s |
| `rtl` | Return to Launch (fin de misión) |
| `land` | aterriza en ese punto |

### Formato JSON exportado

```json
{
  "id": "1715000000000",
  "name": "Plan 01 May 2025",
  "waypoints": [
    { "lat": 41.27650, "lon": 1.98880, "altM": 10.0,
      "action": { "type": "hover", "seconds": 3.0 } }
  ]
}
```

## Librerías

| Paquete | Versión | Uso |
|---|---|---|
| `flutter_map` | `^8.3.0` | mapa satelital (ArcGIS World Imagery) |
| `latlong2` | `^0.9.1` | coordenadas |
| `web` | `^1.1.0` | descarga real del JSON en navegador |

> Esta demo **no publica por MQTT** (solo exporta el JSON a fichero). La publicación
> del plan es cosa de EZDrone — ver "Integración en EZDrone".

## Cómo ejecutar

```bash
flutter pub get
flutter run -d chrome     # la descarga real solo funciona en Web
```

Centro por defecto: campus EETAC (Castelldefels), `41.2765, 1.9888`.

## Integración en EZDrone

El JSON es un formato **similar** al de la misión de EZDrone. La estación de tierra
(`estacion_tierra.py`) lo carga en ArduPilot vía DroneKit y ejecuta cada waypoint
en secuencia.

### ⚠️ En EZDrone es distinto

- **Cómo llega el plan a la ET**: esta demo **descarga el plan a un fichero** local
  (`package:web` Blob). EZDrone no descarga: lo **publica por MQTT** —
  `topicUploadMission` (sube el plan) y `topicStartMission` (lanza la ejecución).
- **Shape del JSON**: EZDrone añade campos de cabecera **`takeoffAlt`** y **`speed`**
  al objeto (la demo solo guarda `id`/`name` + `waypoints`). Los `waypoints` sí
  coinciden en `lat`/`lon`/`altM` + acción.
- `mqtt_client` ya no figura en el `pubspec.yaml` de la demo (no se usaba); la
  publicación MQTT vive en EZDrone, no aquí.
