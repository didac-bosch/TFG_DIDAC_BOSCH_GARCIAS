import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../provider.dart';
import '../core/styles.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'flight_screen.dart';

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('EZDRONE', style: TextStyles.title),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: screenH * 0.06,
      ),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: screenH * 0.04),

            // LOGO
            FaIcon(
              FontAwesomeIcons.helicopterSymbol,
              size: screenW * 0.2,
              color: provider.isConnected
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),

            SizedBox(height: screenH * 0.03),

            // MENSAJE DE ESTADO
            Padding(
              padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: screenW * 0.04,
                  vertical: screenH * 0.015,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.disabled),
                ),
                child: Text(
                  provider.message,
                  textAlign: TextAlign.center,
                  style: TextStyles.status,
                ),
              ),
            ),

            SizedBox(height: screenH * 0.015),

            if (provider.isLoading)
              const CircularProgressIndicator(color: AppColors.primary),

            SizedBox(height: screenH * 0.04),

            // CAMPOS DE CONFIGURACIÓN
            Padding(
              padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  SizedBox(
                    width: screenW * 0.3,
                    child: TextFormField(
                      initialValue: provider.takeoffAltitude.toString(),
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        labelText: 'Alt (m)',
                        helperText: '2.0 - 50.0',
                        helperStyle: TextStyle(
                          color: provider.isConfigValid
                              ? AppColors.textSecondary
                              : AppColors.danger,
                          fontSize: 10,
                        ),
                        labelStyle: const TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: provider.isConfigValid
                                ? AppColors.primary
                                : AppColors.danger,
                          ),
                        ),
                      ),
                      onChanged: (value) =>
                          context.read<DronProvider>().setAltitude(value),
                    ),
                  ),
                  SizedBox(
                    width: screenW * 0.3,
                    child: TextFormField(
                      initialValue: provider.flightSpeed.toString(),
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        labelText: 'Speed (m/s)',
                        helperText: '1.0 - 15.0',
                        helperStyle: TextStyle(
                          color: provider.isConfigValid
                              ? AppColors.textSecondary
                              : AppColors.danger,
                          fontSize: 10,
                        ),
                        labelStyle: const TextStyle(
                          color: AppColors.textSecondary,
                        ),
                        enabledBorder: const UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: provider.isConfigValid
                                ? AppColors.primary
                                : AppColors.danger,
                          ),
                        ),
                      ),
                      onChanged: (value) =>
                          context.read<DronProvider>().setSpeed(value),
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: screenH * 0.04),

            // BOTÓN CONNECT
            Padding(
              padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
              child: SizedBox(
                width: double.infinity,
                height: screenH * 0.07,
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
                  onPressed: provider.isLoading || provider.isConnected
                      ? null
                      : () => context.read<DronProvider>().connectDron(),
                ),
              ),
            ),

            SizedBox(height: screenH * 0.02),

            // BOTÓN START FLIGHT
            Padding(
              padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
              child: SizedBox(
                width: double.infinity,
                height: screenH * 0.07,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.flight_takeoff),
                  label: const Text('START FLIGHT', style: TextStyles.button),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        (provider.isConnected && provider.isConfigValid)
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
            ),

            SizedBox(height: screenH * 0.02),

            // BOTÓN DISCONNECT
            Padding(
              padding: EdgeInsets.symmetric(horizontal: screenW * 0.1),
              child: SizedBox(
                width: double.infinity,
                height: screenH * 0.06,
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
                  onPressed: provider.isLoading || !provider.isConnected
                      ? null
                      : () => context.read<DronProvider>().disconnectDron(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
