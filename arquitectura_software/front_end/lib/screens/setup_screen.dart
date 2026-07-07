import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'flight_screen.dart';



// Stateless widget con un provider que se suscribe a los cambiios y actualiza la pantalla
class SetupScreen extends StatelessWidget {            
  const SetupScreen({super.key});



  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();       //suscripción de widget al provider para que se actualice con los notify



    //pantalla principal de setup, con appbar, logo, mensaje de estado, campos de configuración y botones
    return Scaffold(
      backgroundColor: AppColors.background,
      //appBar
      appBar: AppBar(
        title: const Text('EZDRONE', style: TextStyles.title),   
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [



              const Spacer(),



              // LOGO.    si se hace uno en un futuro cambiar
              FaIcon(
                FontAwesomeIcons.helicopterSymbol,    //librería FontAwesome para mas icons
                size: 128,
                color: provider.isConnected
                    ? AppColors.primary
                    : AppColors.textSecondary,
              ),



              const SizedBox(height: 32),



              // MENSAJE DE ESTADO
              Text(
                provider.message,                 //mensaje guardado en provider según la situación
                textAlign: TextAlign.center,
                style: TextStyles.status,
              ),



              const SizedBox(height: 32),



              // LOADING
              if (provider.isLoading)
                const CircularProgressIndicator(color: AppColors.primary),



              const Spacer(),


              // CAMPOS DE CONFIGURACIÓN (Altitud y Velocidad)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // ALTITUD
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        initialValue: provider.takeoffAltitude.toString(),
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Alt (m)',
                          helperText: '2.0 - 50.0',
                          helperStyle: TextStyle(
                            color: provider.isConfigValid ? AppColors.textSecondary : AppColors.danger,  
                            fontSize: 10    //si no está dentro del rando poner en rojo
                          ),
                          labelStyle: const TextStyle(color: AppColors.textSecondary),
                          enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: AppColors.textSecondary),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: provider.isConfigValid ? AppColors.primary : AppColors.danger
                            ),
                          ),
                        ),
                        onChanged: (value) => context.read<DronProvider>().setAltitude(value), //si se cambia ajustar altitud en el provider
                      ),
                    ),
                    
                    // VELOCIDAD, igual que la altitud
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        initialValue: provider.flightSpeed.toString(),
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Speed (m/s)',
                          helperText: '1.0 - 15.0',
                          helperStyle: TextStyle(
                            color: provider.isConfigValid ? AppColors.textSecondary : AppColors.danger, 
                            fontSize: 10
                          ),
                          labelStyle: const TextStyle(color: AppColors.textSecondary),
                          enabledBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: AppColors.textSecondary),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: provider.isConfigValid ? AppColors.primary : AppColors.danger
                            ),
                          ),
                        ),
                        onChanged: (value) => context.read<DronProvider>().setSpeed(value),
                      ),
                    ),
                  ],
                ),
              ),


              const SizedBox(height: 64),


              // BOTÓN CONNECT
              SizedBox(
                width: 260,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text('CONNECT', style: TextStyles.button),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: provider.isConnected
                        ? AppColors.primary
                        : AppColors.disabled,
                    disabledBackgroundColor: AppColors.disabled,
                    foregroundColor: AppColors.textPrimary,
                    disabledForegroundColor: AppColors.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: provider.isLoading || provider.isConnected         //acción elevated button, si está cargando o ya está conectado no tiene sentido volver a conectar
                      ? null
                      : () => context.read<DronProvider>().connectDron(),     //sino, se conecta, usando read en lugar de watch porque no es necesario suscribirse
                      //en un onpressed de un widget nunca watch ya que flutter no lo permite!
                ),
              ),


              const SizedBox(height: 16),


              // BOTÓN START FLIGHT
              SizedBox(
                width: 260,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.flight_takeoff),
                  label: const Text('START FLIGHT', style: TextStyles.button),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (provider.isConnected && provider.isConfigValid) //si la config. no es valida, no se puede iniciar el vuelo
                        ? AppColors.primary
                        : AppColors.disabled,
                    disabledBackgroundColor: AppColors.disabled,
                    foregroundColor: AppColors.textPrimary,
                    disabledForegroundColor: AppColors.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: (provider.isLoading || !provider.isConnected || !provider.isConfigValid)    //on pressed, if connected &not loading navigator push
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const FlightScreen()),        //builder FlightScreen
                          ),
                ),
              ),


              const Spacer(),



              // BOTÓN DISCONNECT
              SizedBox(
                width: 200,
                height: 44,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text('DISCONNECT', style: TextStyles.button),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    disabledBackgroundColor: AppColors.danger,
                    foregroundColor: AppColors.textPrimary,
                    disabledForegroundColor: AppColors.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: provider.isLoading || !provider.isConnected          //según estado se desconecta
                      ? null
                      : () => context.read<DronProvider>().disconnectDron(),
                ),
              ),



              const SizedBox(height: 24),



            ],
          ),
        ),
      ),
    );
  }
}
