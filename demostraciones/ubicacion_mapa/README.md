# Demo — Ubicación en mapa en tiempo real

Muestra la posición GPS del dispositivo sobre un mapa de OpenStreetMap, en
tiempo real, con un indicador de precisión. Base para pintar la posición del
dron en el mapa de EZDrone.

## Qué demuestra

- Petición de permiso de ubicación al arrancar.
- Stream GPS que emite una nueva posición cada metro.
- Filtrado: la primera lectura siempre se acepta; las siguientes se ignoran si
  el error es mayor a 50 m.
- Badge de precisión en tiempo real:
  - 🟢 verde `< 5 m` (GPS perfecto)
  - 🟠 naranja `< 20 m` (aceptable)
  - 🔴 rojo `> 20 m` (lectura ignorada)

## Librerías

| Paquete | Versión | Uso |
|---|---|---|
| `geolocator` | `^14.0.2` | posición GPS |
| `flutter_map` | `^8.2.2` | render del mapa (sin API key) |
| `latlong2` | `^0.9.1` | coordenadas lat/lng |

## Cómo ejecutar

```bash
flutter pub get
flutter run                 # móvil real recomendado (GPS)
flutter run -d chrome       # Web: usa ubicación del navegador
```

## Permisos

**Android** — `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

**iOS** — `ios/Runner/Info.plist`:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Necesitamos tu ubicación para mostrarte en el mapa</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Necesitamos tu ubicación para mostrarte en el mapa</string>
```

## Integración en EZDrone

Sustituir `_currentPosition` por las coordenadas del dron (telemetría) para
mostrar su posición en tiempo real en la app principal.

### ⚠️ En EZDrone es distinto

Misma base (`flutter_map` + `geolocator`), pero EZDrone usa tiles **satélite de
ArcGIS World Imagery** en lugar de las tiles de calle de **OpenStreetMap** de esta
demo. Es solo el `TileLayer.urlTemplate`; la lógica de GPS/seguimiento es igual.

## Notas

- El mapa centra y sigue la posición con zoom 17 en cada actualización.
- El icono del marcador es configurable (`Icons.navigation`).
