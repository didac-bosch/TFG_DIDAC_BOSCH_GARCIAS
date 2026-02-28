import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class ControlScreen extends StatelessWidget {             //stateless widget con un provider para evitar sobreuso de statefull, 
                                                          //provider reconstruye lo justo y necesario 
  const ControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();       //suscripción de widget al provider para que se actualice con los notify

    //visual
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

              // LOGO
              FaIcon(
                FontAwesomeIcons.helicopterSymbol,    //librería FontAwesome para mas icons
                size: 72,
                color: provider.isConnected
                    ? AppColors.primary
                    : AppColors.textSecondary,
              ),

              const SizedBox(height: 16),

              // MENSAJE DE ESTADO
              Text(
                provider.message,                 //mensaje guardado en provider según la situación
                textAlign: TextAlign.center,
                style: TextStyles.status,
              ),

              const SizedBox(height: 16),

              // LOADING
              if (provider.isLoading)
                const CircularProgressIndicator(color: AppColors.primary),

              const Spacer(),

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
                ),
              ),

              const SizedBox(height: 16),

              // BOTÓN ARM
              SizedBox(
                width: 260,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.warning_amber),
                  label: Text(
                    provider.isArmed ? 'MOTORS ARMED' : 'ARM MOTORS',
                    style: TextStyles.button,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: provider.isArmed
                        ? AppColors.danger
                        : AppColors.warning,
                    disabledBackgroundColor: AppColors.warning,
                    foregroundColor: AppColors.textPrimary,
                    disabledForegroundColor: AppColors.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: provider.isLoading ||        //según los estado se arma o no
                          !provider.isConnected ||
                          provider.isArmed
                      ? null
                      : () => context.read<DronProvider>().armDron(),
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
