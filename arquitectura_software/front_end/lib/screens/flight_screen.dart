import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';



class FlightScreen extends StatelessWidget {      //stateless + provider 
  const FlightScreen({super.key});



  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>(); //suscripción



    Color getBatteryColor(double bat) {     //función para cambio de color según la batería
      if (bat > 50) return AppColors.primary;
      if (bat > 20) return AppColors.warning;
      return AppColors.danger;
    }



    return Scaffold(
      backgroundColor: AppColors.background,



      body: Column(
        children: [
          // BARRA SUPERIOR - telemetría y estado
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // TELEMETRÍA IZQUIERDA
                Expanded(
                  child: Row(
                    children: [ //llama función propia build top telemetry ya que son iguales
                      _buildTopTelemetry( //altitud
                        Icons.height,
                        'ALT',
                        '${provider.currentAlt.toStringAsFixed(1)} m',
                      ),
                      const SizedBox(width: 48),
                      _buildTopTelemetry( //ground speed
                        Icons.speed,
                        'GS',
                        '${provider.currentSpeed.toStringAsFixed(1)} m/s',
                      ),
                      const SizedBox(width: 48),
                      _buildTopTelemetry( //heading
                        Icons.explore,
                        'HDG',
                        '${provider.currentHeading.toInt()}°',
                      ),
                      const SizedBox(width: 48),
                      _buildTopTelemetry( //latitud
                        Icons.location_on,
                        'LAT',
                        provider.currentLat.toStringAsFixed(7), //7 igual que mission planner
                      ),
                      const SizedBox(width: 24),
                      _buildTopTelemetry( //longitud
                        Icons.location_searching,
                        'LON',
                        provider.currentLon.toStringAsFixed(7),
                      ),
                    ],
                  ),
                ),
                // CENTRO - mensaje provider 
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.disabled),
                    ),
                    child: Text(
                      provider.message,       //mensaje del provider
                      textAlign: TextAlign.center,
                      style: TextStyles.status.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),



                // TELEMETRÍA DERECHA
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _buildTopTelemetry( //estado
                        Icons.info_outline,
                        'STATE',
                        provider.currentState,
                      ),
                      const SizedBox(width: 48),
                      _buildTopTelemetry(   //modo
                        Icons.airplanemode_active,
                        'MODE',
                        provider.currentMode,
                      ),
                      const SizedBox(width: 48),



                      provider.isLoading    //si está cargando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: AppColors.primary,
                                strokeWidth: 2,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(  
                                  children: [   //batetía y su respectivo color
                                    Icon(    
                                      Icons.battery_full,
                                      color: getBatteryColor(
                                        provider.currentBat,
                                      ),
                                      size: 14,
                                    ),
                                    const SizedBox(width: 2),
                                    const Text(
                                      'BAT',
                                      style: TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${provider.currentBat.toInt()}%',
                                  style: TextStyle(
                                    color: getBatteryColor(provider.currentBat),
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),



          // ZONA MEDIA (joysticks + camara/mapa)
          Expanded(
            child: Row(
              children: [
                // JOYSTICK IZQ. (por ahora flechas, cambiar a joystick)
                Container(
                  width: 120,
                  color: AppColors.background,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('ALTITUDE', style: TextStyles.status),
                      const SizedBox(height: 20),
                      ContinuousButton(
                        icon: Icons.arrow_upward,
                        direction: 'Up',
                        isEnabled: provider.isFlying,
                      ),
                      const SizedBox(height: 40),
                      ContinuousButton(
                        icon: Icons.arrow_downward,
                        direction: 'Down',
                        isEnabled: provider.isFlying,
                      ),
                    ],
                  ),
                ),



                // ZONA CENTRAL (por ahora mapa con ubicación del dron, falta intercambio con cámara)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16.0,
                      horizontal: 8.0,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(                          // ← NUEVO: Stack para superponer badge
                        children: [
                          FlutterMap(    //Crea flutterMap de la librería flutter map
                            options: MapOptions(
                              initialCenter: LatLng(          //inicio centrado en la eetac
                                provider.currentLat != 0.0
                                    ? provider.currentLat
                                    : 41.2765,
                                provider.currentLon != 0.0
                                    ? provider.currentLon
                                    : 1.9888,
                              ),
                              initialZoom: 18,
                            ),
                            children: [
                              // Capa de tiles (OpenStreetMap)
                              TileLayer(
                                urlTemplate:
                                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.example.app',
                              ),
                              // Traza 
                              if (provider.droneTrail.length > 1)
                                PolylineLayer(
                                  polylines: [
                                    Polyline(
                                      points: provider.droneTrail,
                                      color: const Color.fromARGB(255, 121, 40, 198),
                                      strokeWidth: 2.5,
                                    ),
                                  ],
                                ),



                              // Vector de velocidad - línea hacia donde se mueve
                              if (provider.isFlying)
                                PolylineLayer(
                                  polylines: [
                                    Polyline(
                                      points: [
                                        LatLng(provider.currentLat, provider.currentLon),
                                        _calcVelocityEndPoint(
                                          provider.currentLat,
                                          provider.currentLon,
                                          provider.currentVx / 100, 
                                          provider.currentVy / 100,
                                        ),
                                      ],
                                      color: const Color.fromARGB(255, 0, 255, 132),
                                      strokeWidth: 2.5,
                                    ),
                                  ],
                                ),



                              // Sombra del dron (solo cuando vuela)
                              if (provider.isFlying)
                                CircleLayer(
                                  circles: [
                                    CircleMarker(
                                      point: LatLng(
                                        provider.currentLat,
                                        provider.currentLon,
                                      ),
                                      radius: 20,
                                      color: const Color.fromARGB(181, 171, 171, 171),
                                      borderColor: Colors.grey,
                                      borderStrokeWidth: 1,
                                      useRadiusInMeter: false,
                                    ),
                                  ],
                                ),



                              // dron
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: LatLng(          //en las coords
                                      provider.currentLat,
                                      provider.currentLon,
                                    ),
                                    width: 48,
                                    height: 48,
                                    child: Transform.rotate(
                                      angle: provider.currentHeading * (pi / 180), 
                                      child: Image.asset(
                                        'assets/images/drone_icon.png',
                                        color: AppColors.primary,
                                        colorBlendMode: BlendMode.srcIn,
                                      ),
                                    ),
                                  ),
                                ],
                              ),



                              // Flecha de dirección encima del dron
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: LatLng(
                                      provider.currentLat,
                                      provider.currentLon,
                                    ),
                                    width: 80,
                                    height: 100, 
                                    child: Transform.rotate(
                                      angle: provider.currentHeading * (pi / 180),    //apunta hacia donde mira el dron
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.start,
                                        children: [
                                          Icon(
                                            Icons.arrow_upward,
                                            color: AppColors.warning,
                                            size: 36,
                                          ),
                                          const SizedBox( //sized box para separarlo un poco del dron
                                            height: 20,
                                          ), 
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              if (provider.userPosition != null)
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: provider.userPosition!,
                                      width: 50,
                                      height: 50,
                                      child: const Icon(
                                        Icons.phone_android_outlined,
                                        color: Colors.blue,
                                        size: 36,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),

                          if (provider.userPosition != null)
                            Positioned(
                              bottom: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.gps_fixed, color: _gpsColor(provider.gpsAccuracy), size: 14),
                                    const SizedBox(width: 6),
                                    Text(
                                      'GPS: ${provider.gpsAccuracy.toStringAsFixed(1)} m',
                                      style: TextStyle(
                                        color: _gpsColor(provider.gpsAccuracy),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),



                // ZONA DER. (por ahora flechas, cambiar a joystick)
                Container(
                  width: 160,
                  color: AppColors.background,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('DIRECTION', style: TextStyles.status),
                      const SizedBox(height: 15),
                      ContinuousButton(
                        icon: Icons.arrow_upward,
                        direction: 'Forward',
                        isEnabled: provider.isFlying,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ContinuousButton(
                            icon: Icons.arrow_back,
                            direction: 'Left',
                            isEnabled: provider.isFlying,
                          ),
                          const SizedBox(width: 30), // Espacio en el centro de la cruz
                          ContinuousButton(
                            icon: Icons.arrow_forward,
                            direction: 'Right',
                            isEnabled: provider.isFlying,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ContinuousButton(
                        icon: Icons.arrow_downward,
                        direction: 'Back',
                        isEnabled: provider.isFlying,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
 
          // BARRA INFERIOR - botones de vuelo.  (hacen .read al provider para acceder a las funciones)
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // BOTÓN ARM
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.warning_amber, size: 18),
                    label: Text(
                      provider.isArmed ? 'ARMED' : 'ARM',
                      style: TextStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: provider.isArmed
                          ? AppColors.danger
                          : AppColors.warning,
                      disabledBackgroundColor: AppColors.warning,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed:
                        provider.isLoading ||
                            !provider.isConnected ||
                            provider.isArmed
                        ? null
                        : () => context.read<DronProvider>().armDron(),
                  ),
                ),
                const SizedBox(width: 8),



                // BOTÓN TAKEOFF
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.flight_takeoff, size: 18),
                    label: const Text(
                      'TAKEOFF',
                      style: TextStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed:
                        provider.isLoading ||
                            !provider.isConnected ||
                            !provider.isArmed ||
                            provider.isFlying
                        ? null
                        : () => context.read<DronProvider>().takeOff(),
                  ),
                ),
                const SizedBox(width: 8),



                // BOTÓN DISCONNECT
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text(
                      'DISCONNECT',
                      style: TextStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      disabledBackgroundColor: AppColors.danger,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    // No permite desconectar si está armado o volando
                    onPressed:
                        provider.isLoading ||
                            !provider.isConnected ||
                            provider.isArmed ||
                            provider.isFlying
                        ? null
                        : () {
                            context.read<DronProvider>().disconnectDron();
                            Navigator.pop(context); //vuelve a la pantalla de setup al desconectar
                          },
                  ),
                ),
                const SizedBox(width: 8),



                // BOTÓN LAND
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.flight_land, size: 18),
                    label: const Text(
                      'LAND',
                      style: TextStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.warning,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed:
                        provider.isLoading ||
                            !provider.isConnected ||
                            !provider.isFlying
                        ? null
                        : () => context.read<DronProvider>().land(),
                  ),
                ),
                const SizedBox(width: 8),



                // BOTÓN RTL
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.home, size: 18),
                    label: const Text(
                      'RTL',
                      style: TextStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.warning,
                      disabledBackgroundColor: AppColors.disabled,
                      foregroundColor: AppColors.textPrimary,
                      disabledForegroundColor: AppColors.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed:
                        provider.isLoading ||
                            !provider.isConnected ||
                            !provider.isFlying
                        ? null
                        : () => context.read<DronProvider>().rtl(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



Widget _buildTopTelemetry(IconData icon, String label, String value) { //función para facilitar el display de la telem.
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 14),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
      Text(
        value,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}

// ← NUEVO: helper color badge GPS
Color _gpsColor(double accuracy) {
  if (accuracy <= 5) return Colors.green;
  if (accuracy <= 20) return Colors.orange;
  return Colors.red;
}



class ContinuousButton extends StatefulWidget {   //statefull widget de los botones 
  final IconData icon;
  final String direction;
  final bool isEnabled;



  const ContinuousButton({
    super.key,
    required this.icon,
    required this.direction,
    required this.isEnabled,
  });



  @override
  State<ContinuousButton> createState() => _ContinuousButtonState();
}



class _ContinuousButtonState extends State<ContinuousButton> {
  bool _isPressed = false;



  void _handlePressDown(_) {        //cuando está apretado =move
    if (!widget.isEnabled) return;
    setState(() => _isPressed = true);
    context.read<DronProvider>().startMove(widget.direction);
  }



  void _handlePressUp(_) {          //cuando se suelta = stop
    if (!widget.isEnabled) return;
    setState(() => _isPressed = false);
    context.read<DronProvider>().stopMove();
  }



  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _handlePressDown,
      onTapUp: _handlePressUp,
      onTapCancel: () => _handlePressUp(null), // Misma lógica al cancelar
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100), 
        width: _isPressed ? 45 : 50, // Se hace un poquito más pequeño al pulsar
        height: _isPressed ? 45 : 50,
        decoration: BoxDecoration(
          color: widget.isEnabled
              ? (_isPressed
                    ? AppColors.warning
                    : AppColors.primary) // Cambia de color al pulsar
              : AppColors.disabled,
          shape: BoxShape.circle,
          boxShadow: _isPressed || !widget.isEnabled
              ? []
              : [
                  const BoxShadow(
                    color: Colors.black,
                    blurRadius: 5,
                    offset: Offset(0, 3),
                  ),
                ],
        ),
        child: Center(
          child: Icon(
            widget.icon,
            color: AppColors.textPrimary,
            size: _isPressed ? 25 : 30, // El icono también encoge un poco
          ),
        ),
      ),
    );
  }
}



LatLng _calcVelocityEndPoint(double lat, double lon, double vx, double vy) {
  final speed = sqrt(vx * vx + vy * vy);
  if (speed < 0.3) return LatLng(lat, lon); 
  final scale = 6.0;
  final dlat = (vx * scale) / 111320;
  final dlon = (vy * scale) / (111320 * cos(lat * pi / 180));
  return LatLng(lat + dlat, lon + dlon);
}
