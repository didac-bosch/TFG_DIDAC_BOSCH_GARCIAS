import 'dart:js_interop';
import 'dart:math';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:web/web.dart' as web;
import '../provider.dart';
import '../core/styles.dart';
import '../core/js_bridges.dart';
import 'flight_plan_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FlightLogScreen — todo lo que la app guarda entre sesiones, en tres pestañas:
//   LOGS    — vuelos grabados: recorrido en el mapa, estadísticas y export a CSV.
//   PLANS   — planes de vuelo guardados, para reabrirlos en el planificador.
//   GALLERY — fotos, vídeos y panorámicas capturadas.
//
// Nada de esto habla con el dron: se lee todo del provider, que a su vez lo saca
// del almacenamiento del navegador (metadatos en localStorage y los archivos
// pesados en IndexedDB).
// ─────────────────────────────────────────────────────────────────────────────
class FlightLogScreen extends StatefulWidget {
  const FlightLogScreen({super.key});

  @override
  State<FlightLogScreen> createState() => _FlightLogScreenState();
}

class _FlightLogScreenState extends State<FlightLogScreen> {
  int _tab = 0; // 0 = LOGS, 1 = PLANS, 2 = GALLERY
  bool get _showPlans => _tab == 1;
  bool get _showGallery => _tab == 2;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DronProvider>();
    final sessions = provider.flightHistory;
    final plans = provider.flightPlans;
    final media = provider.mediaGallery;
    final screenH = MediaQuery.of(context).size.height;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          _showGallery
              ? 'GALLERY'
              : _showPlans
              ? 'FLIGHT PLANS'
              : 'FLIGHT LOG',
          style: TextStyles.title,
        ),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLandscape ? screenH * 0.09 : screenH * 0.06,
        actions: [
          if (_showGallery) ...[
            // Badge media
            if (media.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${media.length}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            if (media.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: AppColors.danger),
                tooltip: 'Clear gallery',
                onPressed: () => _confirmClearGallery(context),
              ),
          ] else if (!_showPlans) ...[
            // Badge sesiones
            if (sessions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.primary),
                    ),
                    child: Text(
                      '${sessions.length}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            if (sessions.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: AppColors.danger),
                tooltip: 'Clear all flights',
                onPressed: () => _confirmClearAll(context),
              ),
          ] else ...[
            // Badge planes
            if (plans.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${plans.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            if (plans.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: AppColors.danger),
                tooltip: 'Clear all plans',
                onPressed: () => _confirmClearPlans(context),
              ),
          ],
          const SizedBox(width: 4),
        ],
      ),

      // FAB — solo visible en Plans tab para crear nuevo plan
      floatingActionButton: _showPlans
          ? FloatingActionButton.small(
              backgroundColor: AppColors.primary,
              tooltip: 'New plan',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FlightPlanScreen()),
              ),
              child: const Icon(Icons.add, color: AppColors.textPrimary),
            )
          : null,

      body: Column(
        children: [
          // ── Tab toggle ────────────────────────────────────────────────────
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: _TabButton(
                    label: 'LOGS',
                    icon: Icons.history,
                    selected: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TabButton(
                    label: 'PLANS',
                    icon: Icons.map_outlined,
                    selected: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TabButton(
                    label: 'GALLERY',
                    icon: Icons.photo_library_outlined,
                    selected: _tab == 2,
                    onTap: () => setState(() => _tab = 2),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.disabled),

          // ── Contenido ─────────────────────────────────────────────────────
          Expanded(
            child: _showGallery
                ? _buildGalleryTab(context, provider)
                : _showPlans
                ? _buildPlansTab(context, provider)
                : _buildLogsTab(sessions),
          ),
        ],
      ),
    );
  }

  // ── Logs tab (contenido original) ─────────────────────────────────────────
  Widget _buildLogsTab(List<FlightSession> sessions) {
    if (sessions.isEmpty) return _buildEmptyLogs();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: sessions.length,
      itemBuilder: (ctx, i) => _SessionCard(session: sessions[i], realIndex: i),
    );
  }

  Widget _buildEmptyLogs() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flight_land, size: 64, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text(
            'No flights yet',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Complete a flight to see it here',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── Plans tab ─────────────────────────────────────────────────────────────
  Widget _buildPlansTab(BuildContext context, DronProvider provider) {
    final plans = provider.flightPlans;
    if (plans.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: AppColors.textSecondary),
            SizedBox(height: 16),
            Text(
              'No plans yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap + to create your first flight plan',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: plans.length,
      itemBuilder: (ctx, i) => _PlanCard(plan: plans[i], provider: provider),
    );
  }

  // ── Gallery tab ─────────────────────────────────────────────────────────────
  Widget _buildGalleryTab(BuildContext context, DronProvider provider) {
    final media = provider.mediaGallery;
    if (media.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: AppColors.textSecondary,
            ),
            SizedBox(height: 16),
            Text(
              'No captures yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Take a photo or record a video during a flight',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: media.length,
      itemBuilder: (ctx, i) => _MediaCard(
        item: media[i],
        onOpen: () => _openMedia(context, media[i]),
        onDelete: () => _confirmDeleteMedia(context, media[i]),
      ),
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────────────────
  void _confirmClearGallery(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear gallery?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will permanently delete all captures and videos.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().clearMediaGallery();
              Navigator.pop(context);
            },
            child: const Text(
              'Delete all',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClearPlans(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear all plans?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will permanently delete all flight plans.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().clearAllFlightPlans();
              Navigator.pop(context);
            },
            child: const Text(
              'Delete all',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Clear all flights?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will permanently delete all flight records.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().clearAllSessions();
              Navigator.pop(context);
            },
            child: const Text(
              'Delete all',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── GALLERY HELPERS ──────────────────────────────────────────────────────────
// Registra un <video> HTML (con controles) para reproducir el blob: URL inline.
final Set<String> _registeredVideoViews = {};

String _registerVideoView(String url) {
  final viewType = 'ez-video-$url';
  if (!_registeredVideoViews.contains(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final v = web.HTMLVideoElement()
        ..src = url
        ..controls = true
        ..autoplay = true;
      v.style
        ..width = '100%'
        ..height = '100%'
        ..backgroundColor = 'black';
      return v;
    });
    _registeredVideoViews.add(viewType);
  }
  return viewType;
}

// Abre un visor a pantalla completa: foto con zoom o vídeo HTML5. Top-level
// para reutilizarlo tanto en la galería como en el detalle de un vuelo.
void _openMedia(BuildContext context, MediaItem item) {
  final url = ezGetMediaUrl(item.id);
  if (url.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Media not available')),
    );
    return;
  }
  // Las panorámicas 360 se abren en el visor interactivo (Three.js) en vez de
  // mostrarse planas: arrastrar gira 360º, la rueda hace zoom.
  if (item.isPanorama) {
    openPanoramaViewer(item.id);
    return;
  }
  showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          Center(
            child: item.isPhoto
                ? InteractiveViewer(
                    child: Image.network(url, fit: BoxFit.contain),
                  )
                : AspectRatio(
                    aspectRatio: 16 / 9,
                    child: HtmlElementView(
                      viewType: _registerVideoView(url),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    ),
  );
}

// Confirma y borra un medio de la galería (la fuente de la verdad). Las refs
// en cualquier FlightSession se filtran solas al haber desaparecido el id.
void _confirmDeleteMedia(BuildContext context, MediaItem item) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text(
        'Delete capture?',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: const Text(
        'This will remove it from the gallery.',
        style: TextStyle(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () {
            context.read<DronProvider>().deleteMediaItem(item.id);
            Navigator.pop(context);
          },
          child: const Text(
            'Delete',
            style: TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
}

// Tarjeta de la galería — miniatura de foto o portada de vídeo con metadata.
class _MediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _MediaCard({
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}  ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final url = ezGetMediaUrl(item.id);
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Miniatura
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if ((item.isPhoto || item.isPanorama) && url.isNotEmpty)
                    Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Colors.black26,
                        child: Icon(
                          Icons.broken_image,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  else
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: Icon(
                          item.isPhoto
                              ? Icons.image
                              : Icons.play_circle_fill,
                          color: Colors.white70,
                          size: 44,
                        ),
                      ),
                    ),
                  // Las panorámicas se abren en el visor 360: overlay indicativo.
                  if (item.isPanorama)
                    const Center(
                      child: Icon(
                        Icons.threesixty,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  // Insignia tipo
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        item.isPanorama
                            ? Icons.panorama_photosphere
                            : item.isPhoto
                                ? Icons.photo_camera
                                : Icons.videocam,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                  // Botón borrar
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                        size: 18,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black45,
                        minimumSize: const Size(30, 30),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: onDelete,
                    ),
                  ),
                ],
              ),
            ),
            // Metadata
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatDate(item.timestamp),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (item.hasGps)
                    Text(
                      '${item.lat!.toStringAsFixed(5)}, ${item.lon!.toStringAsFixed(5)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TAB BUTTON ───────────────────────────────────────────────────────────────
class _TabButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.15)
              : AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.disabled,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.primary : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PLAN CARD ────────────────────────────────────────────────────────────────
class _PlanCard extends StatelessWidget {
  final FlightPlan plan;
  final DronProvider provider;

  const _PlanCard({required this.plan, required this.provider});

  @override
  Widget build(BuildContext context) {
    final dist = plan.totalDistanceM;
    final distStr = dist < 1000
        ? '${dist.toStringAsFixed(0)} m'
        : '${(dist / 1000).toStringAsFixed(2)} km';
    final createdStr = _fmtDate(plan.createdAt);

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FlightPlanScreen(existingPlan: plan)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cabecera
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Chip nº waypoints
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.teal),
                    ),
                    child: Text(
                      '${plan.waypoints.length} WP',
                      style: const TextStyle(
                        color: Colors.teal,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => _downloadFlightPlan(plan),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.download_outlined,
                        size: 16,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  // Borrar
                  GestureDetector(
                    onTap: () => _confirmDelete(context),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Fecha
              Text(
                'Created $createdStr',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 10),
              // Stats
              Row(
                children: [
                  _PlanStat(Icons.straighten, distStr, 'Distance'),
                  const SizedBox(width: 20),
                  _PlanStat(
                    Icons.location_on_outlined,
                    '${plan.waypoints.length}',
                    'Waypoints',
                  ),
                  if (plan.waypoints.isNotEmpty) ...[
                    const SizedBox(width: 20),
                    _PlanStat(
                      Icons.height,
                      '${plan.waypoints.map((w) => w.altM).reduce((a, b) => a > b ? a : b).toStringAsFixed(0)} m',
                      'Max Alt',
                    ),
                  ],
                ],
              ),
              // ── Botones UPLOAD / START ────────────────────────────
              if (provider.isConnected) ...[
                const SizedBox(height: 10),
                const Divider(height: 1, color: AppColors.disabled),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.upload, size: 14),
                        label: const Text(
                          'UPLOAD',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () => provider.uploadMission(plan),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 14),
                        label: const Text(
                          'START',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              provider.missionUploaded &&
                                  provider.currentMissionPlanId == plan.id
                              ? Colors.teal
                              : AppColors.disabled,
                          foregroundColor: AppColors.textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed:
                            provider.missionUploaded &&
                                provider.currentMissionPlanId == plan.id
                            ? () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        FlightPlanScreen(existingPlan: plan),
                                  ),
                                );
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Delete this plan?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          '"${plan.name}" will be permanently deleted.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().deleteFlightPlan(plan.id);
              Navigator.pop(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $h:$m';
  }
}

String _buildWaypoints(FlightPlan plan) {
  final sb = StringBuffer();
  sb.writeln('QGC WPL 110');

  // Fila 0: home — mismas coords que el primer WP, altitud 0
  final home = plan.waypoints.isNotEmpty
      ? plan.waypoints.first
      : const FlightWaypoint(lat: 41.2765, lon: 1.9888);
  sb.writeln(
    '0\t1\t0\t16\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t'
    '${home.lat.toStringAsFixed(7)}\t${home.lon.toStringAsFixed(7)}\t0.000000\t1',
  );

  for (int i = 0; i < plan.waypoints.length; i++) {
    final wp = plan.waypoints[i];
    final idx = i + 1;
    final lat = wp.lat.toStringAsFixed(8);
    final lon = wp.lon.toStringAsFixed(8);
    final alt = wp.altM.toStringAsFixed(6);

    switch (wp.action.type) {
      case WaypointActionType.none:
      case WaypointActionType.takePhoto:
      case WaypointActionType.recordVideo:
        // NAV_WAYPOINT sin espera (CMD 2000 = variante ArduPilot simple)
        sb.writeln(
          '$idx\t0\t3\t2000\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t$lat\t$lon\t$alt\t1',
        );
      case WaypointActionType.hover:
        // NAV_WAYPOINT con espera en PARAM1
        final secs = wp.action.seconds.toStringAsFixed(8);
        sb.writeln(
          '$idx\t0\t3\t16\t$secs\t0.00000000\t0.00000000\t0.00000000\t$lat\t$lon\t$alt\t1',
        );
      case WaypointActionType.rtl:
        // NAV_RETURN_TO_LAUNCH — sin coords
        sb.writeln(
          '$idx\t0\t3\t20\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t0.000000\t1',
        );
      case WaypointActionType.land:
        // NAV_LAND
        sb.writeln(
          '$idx\t0\t3\t21\t0.00000000\t0.00000000\t0.00000000\t0.00000000\t$lat\t$lon\t0.000000\t1',
        );
    }
  }

  return sb.toString();
}

class _PlanStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _PlanStat(this.icon, this.value, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppColors.primary),
        const SizedBox(width: 3),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

//-------- LISTA DE SESIONES ------------------

// Tarjeta de resumen de una sesión.
// Muestra los datos más relevantes y abre el detail sheet al pulsar.
class _SessionCard extends StatelessWidget {
  final FlightSession session;
  final int realIndex; // índice real en flightHistory para poder borrarlo

  const _SessionCard({required this.session, required this.realIndex});

  @override
  Widget build(BuildContext context) {
    final modeColor = _modeColor(session.controlMode);
    final distStr = _formatDistance(session.totalDistanceM);
    final durStr = _formatDuration(session.duration);

    return GestureDetector(
      onTap: () => _openDetail(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: session.completed ? AppColors.disabled : AppColors.warning,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cabecera: nombre del vuelo, modo, estado y borrar
              Row(
                children: [
                  // Nombre: Flight + fecha y hora de inicio
                  Expanded(
                    child: Text(
                      'Flight  ${_formatDate(session.startTime)}',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Chip del modo de control con su color propio
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: modeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: modeColor),
                    ),
                    child: Text(
                      session.controlMode.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Chip SITL — solo si fue simulación
                  if (session.isSitl)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange),
                      ),
                      child: const Text(
                        'SITL',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  if (session.isSitl) const SizedBox(width: 4),
                  // Botón borrar esta sesión
                  GestureDetector(
                    onTap: () => _confirmDelete(context),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Indicador completado / interrumpido
              Row(
                children: [
                  Icon(
                    session.completed
                        ? Icons.check_circle
                        : Icons.warning_amber,
                    size: 12,
                    color: session.completed
                        ? AppColors.primary
                        : AppColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    session.completed ? 'Completed' : 'Interrupted',
                    style: TextStyle(
                      color: session.completed
                          ? AppColors.primary
                          : AppColors.warning,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ----- DATOS PRINCIPALES: duración, distancia, altitud máxima, desnivel y velocidad máxima -------------
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _MetricTile(Icons.timer_outlined, durStr, 'Duration'),
                  _MetricTile(Icons.straighten, distStr, 'Distance'),
                  _MetricTile(
                    Icons.height,
                    '${session.maxAlt.toStringAsFixed(1)} m',
                    'Max Alt',
                  ),
                  _MetricTile(
                    Icons.trending_up,
                    '${session.altGain.toStringAsFixed(1)} m',
                    'Desnivel',
                  ),
                  _MetricTile(
                    Icons.speed,
                    '${session.maxSpeed.toStringAsFixed(1)} m/s',
                    'Max Spd',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Diálogo de confirmación para borrar esta sesión concreta
  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Delete this flight?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Flight ${_formatDate(session.startTime)} will be permanently deleted.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              context.read<DronProvider>().deleteFlightSession(realIndex);
              Navigator.pop(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  // Abre el bottom sheet de detalle con mapa y estadísticas completas
  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FlightDetailSheet(session: session),
    );
  }
}

// Tile de métrica reutilizable dentro de la card
class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _MetricTile(this.icon, this.value, this.label);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.primary, size: 14),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 9),
        ),
      ],
    );
  }
}

// --------- DETAIL SHEET DE LA SESIÓN ----------------

class _FlightDetailSheet extends StatefulWidget {
  final FlightSession session;

  const _FlightDetailSheet({required this.session});

  @override
  State<_FlightDetailSheet> createState() => _FlightDetailSheetState();
}

// Bottom sheet de detalle — mapa interactivo del trail + grid de estadísticas + botón de descarga CSV.
class _FlightDetailSheetState extends State<_FlightDetailSheet> {
  final MapController _mapController = MapController();
  int _playIndex = 0; // índice hasta donde se muestra el trail

  @override
  void initState() {
    super.initState();
    // Arranca con el slider al final: al abrir el detalle se ve el recorrido
    // completo, y desde ahí el usuario puede retroceder para "rebobinar".
    _playIndex = (widget.session.trail.length - 1).clamp(
      0,
      double.maxFinite.toInt(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitTrail());
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // Encuadra el mapa para que se vea el recorrido entero: se busca el rectángulo
  // que contiene todos los puntos (esquinas suroeste y noreste) y se le pide al
  // mapa que se ajuste a él, con un margen para que no toque los bordes.
  void _fitTrail() {
    final trail = widget.session.trail;
    if (trail.isEmpty) return;
    if (trail.length == 1) {
      try {
        _mapController.move(trail.first, 17);
      } catch (_) {}
      return;
    }
    final lats = trail.map((p) => p.latitude);
    final lons = trail.map((p) => p.longitude);
    final sw = LatLng(lats.reduce(min), lons.reduce(min));
    final ne = LatLng(lats.reduce(max), lons.reduce(max));
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(sw, ne),
          padding: const EdgeInsets.all(48),
        ),
      );
    } catch (_) {}
  }

  // Convierte el log del vuelo a CSV: una línea de cabecera con los nombres de
  // columna y una línea por cada muestra de telemetría. Es texto plano, así que
  // se abre directamente en Excel o en cualquier herramienta de análisis.
  String _buildCSV() {
    final sb = StringBuffer();
    sb.writeln('timestamp,lat,lon,alt_m,speed_ms,bat_pct,heading_deg');
    for (final s in widget.session.log) {
      sb.writeln(
        '${s.timestamp.toIso8601String()},'
        '${s.lat.toStringAsFixed(7)},'
        '${s.lon.toStringAsFixed(7)},'
        '${s.alt.toStringAsFixed(2)},'
        '${s.speed.toStringAsFixed(2)},'
        '${s.bat.toStringAsFixed(1)},'
        '${s.heading.toStringAsFixed(1)}',
      );
    }
    return sb.toString();
  }

  // Resuelve los MediaItem capturados en este vuelo desde la galería (fuente de
  // la verdad), descartando refs cuyo medio ya se haya borrado.
  List<MediaItem> _sessionMedia(DronProvider p) => widget.session.mediaIds
      .map((id) => p.mediaGallery.where((m) => m.id == id))
      .expand((e) => e)
      .toList();

  // La descarga la hace JavaScript (downloadCSVEZ, en web/index.html): Flutter
  // Web no puede escribir en el disco, así que se genera un fichero en memoria y
  // se simula un clic en un enlace de descarga.
  // Los ':' de la hora se sustituyen por '-' porque hay sistemas de ficheros que
  // no los admiten en un nombre.
  void _downloadCSV() {
    final csv = _buildCSV();
    final dateStr = widget.session.startTime
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    downloadCSVEZ('flight_$dateStr.csv', csv);
  }

  // Devuelve el snapshot del log correspondiente al punto actual del slider
  // (interpola el índice del trail al índice del log)
  String _snapshotInfo() {
    final log = widget.session.log;
    if (log.isEmpty || widget.session.trail.isEmpty) return '';
    final ratio =
        _playIndex / (widget.session.trail.length - 1).clamp(1, 999999);
    final logIdx = (ratio * (log.length - 1)).round().clamp(0, log.length - 1);
    final s = log[logIdx];
    final h = s.heading.toStringAsFixed(0);
    final alt = s.alt.toStringAsFixed(1);
    final spd = s.speed.toStringAsFixed(1);
    final bat = s.bat.toStringAsFixed(0);
    return 'Alt ${alt}m  ·  ${spd}m/s  ·  HDG ${h}°  ·  BAT ${bat}%';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final trail = session.trail;
    final hasTrail = trail.length >= 2;
    final modeColor = _modeColor(session.controlMode);
    // Medios capturados durante este vuelo (vista filtrada de la galería)
    final sessionMedia = _sessionMedia(context.watch<DronProvider>());

    // Trail visible: solo hasta _playIndex
    final visibleTrail = hasTrail
        ? trail.sublist(0, _playIndex + 1)
        : <LatLng>[];
    final currentPoint = hasTrail ? trail[_playIndex] : null;

    final LatLng mapCenter = hasTrail
        ? LatLng(
            trail.map((p) => p.latitude).reduce((a, b) => a + b) / trail.length,
            trail.map((p) => p.longitude).reduce((a, b) => a + b) /
                trail.length,
          )
        : const LatLng(41.2765, 1.9888);

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.disabled,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Cabecera ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Flight  ${_formatDate(session.startTime)}',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Icon(
                              session.completed
                                  ? Icons.check_circle
                                  : Icons.warning_amber,
                              size: 12,
                              color: session.completed
                                  ? AppColors.primary
                                  : AppColors.warning,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              session.completed ? 'Completed' : 'Interrupted',
                              style: TextStyle(
                                color: session.completed
                                    ? AppColors.primary
                                    : AppColors.warning,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Chip del modo
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: modeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: modeColor),
                    ),
                    child: Text(
                      session.controlMode.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Chip SITL
                  if (session.isSitl) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange),
                      ),
                      child: const Text(
                        'SITL',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Mapa ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 240,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: hasTrail
                      ? FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: mapCenter,
                            initialZoom: 17,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/'
                                  'World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName: 'com.example.app',
                            ),
                            // Trail completo en gris tenue de fondo
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: trail,
                                  color: Colors.white24,
                                  strokeWidth: 2.0,
                                ),
                              ],
                            ),
                            // Trail visible hasta _playIndex en color primario
                            if (visibleTrail.length >= 2)
                              PolylineLayer(
                                polylines: [
                                  Polyline(
                                    points: visibleTrail,
                                    color: const Color.fromARGB(
                                      255,
                                      121,
                                      40,
                                      198,
                                    ),
                                    strokeWidth: 2.0,
                                  ),
                                ],
                              ),

                            // Marcadores despegue / aterrizaje
                            MarkerLayer(
                              markers: [
                                _buildMarker(
                                  point: trail.first,
                                  icon: Icons.flight_takeoff,
                                  color: AppColors.primary,
                                ),
                                _buildMarker(
                                  point: trail.last,
                                  icon: session.completed
                                      ? Icons.flight_land
                                      : Icons.warning_amber,
                                  color: session.completed
                                      ? AppColors.danger
                                      : AppColors.warning,
                                ),
                                // Marcador dron en posición actual del slider
                                if (currentPoint != null)
                                  Marker(
                                    point: currentPoint,
                                    width: 34,
                                    height: 34,
                                    child: Transform.rotate(
                                      angle: _droneHeading(),
                                      child: Image.asset(
                                        'assets/images/drone_icon.png',
                                        width: 30,
                                        height: 30,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        )
                      : Container(
                          color: AppColors.background,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.gps_off,
                                  color: AppColors.textSecondary,
                                  size: 36,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'No GPS data available',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),

            // ── Slider de tiempo ─────────────────────────────────
            if (hasTrail) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    // Info del snapshot actual
                    Center(
                      child: Text(
                        _snapshotInfo(),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: AppColors.primary,
                        inactiveTrackColor: AppColors.disabled,
                        thumbColor: AppColors.primary,
                        overlayColor: AppColors.primary,
                      ),
                      child: Slider(
                        value: _playIndex.toDouble(),
                        min: 0,
                        max: (trail.length - 1).toDouble(),
                        // Sin divisions para movimiento suave
                        onChanged: (v) =>
                            setState(() => _playIndex = v.round()),
                      ),
                    ),
                    // Etiquetas inicio / fin
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDate(session.startTime),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9,
                            ),
                          ),
                          Text(
                            _formatDate(
                              session.startTime.add(session.duration),
                            ),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            // ── Estadísticas ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _StatCard(
                        Icons.timer_outlined,
                        'Duration',
                        _formatDuration(session.duration),
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.straighten,
                        'Distance',
                        _formatDistance(session.totalDistanceM),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.height,
                        'Max Alt',
                        '${session.maxAlt.toStringAsFixed(1)} m',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.trending_up,
                        'Desnivel',
                        '${session.altGain.toStringAsFixed(1)} m',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.speed,
                        'Max Speed',
                        '${session.maxSpeed.toStringAsFixed(1)} m/s',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.battery_full,
                        'Min Battery',
                        '${session.minBat.toStringAsFixed(0)} %',
                        valueColor: session.minBat < 20
                            ? AppColors.danger
                            : session.minBat < 50
                            ? AppColors.warning
                            : AppColors.primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _StatCard(
                        Icons.format_list_numbered,
                        'Snapshots',
                        '${session.log.length}',
                      ),
                      const SizedBox(width: 10),
                      _StatCard(
                        Icons.check_circle_outline,
                        'Status',
                        session.completed ? 'Completed' : 'Interrupted',
                        valueColor: session.completed
                            ? AppColors.primary
                            : AppColors.warning,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── Fotos y vídeos del vuelo ──────────────────────────
            if (sessionMedia.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(
                      Icons.photo_library_outlined,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Gallery',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
                itemCount: sessionMedia.length,
                itemBuilder: (ctx, i) => _MediaCard(
                  item: sessionMedia[i],
                  onOpen: () => _openMedia(context, sessionMedia[i]),
                  onDelete: () => _confirmDeleteMedia(context, sessionMedia[i]),
                ),
              ),
              const SizedBox(height: 24),
            ],

            // ── Botón CSV ─────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text(
                    'DOWNLOAD CSV',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textPrimary,
                    disabledBackgroundColor: AppColors.disabled,
                    disabledForegroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: session.log.isEmpty ? null : _downloadCSV,
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // Calcula el ángulo de orientación del dron en el punto actual del slider
  double _droneHeading() {
    final trail = widget.session.trail;
    if (trail.length < 2 || _playIndex == 0) return 0;
    final from = trail[_playIndex - 1];
    final to = trail[_playIndex];
    final lat1 = from.latitude * pi / 180;
    final lat2 = to.latitude * pi / 180;
    final dLon = (to.longitude - from.longitude) * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return atan2(y, x);
  }

  Marker _buildMarker({
    required LatLng point,
    required IconData icon,
    required Color color,
  }) {
    return Marker(
      point: point,
      width: 26,
      height: 26,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(icon, color: Colors.white, size: 12),
      ),
    );
  }
}

// Tarjeta de estadística individual — icono + etiqueta + valor
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCard(this.icon, this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.disabled),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: 20),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --------- FUNCIONES AUXILIARES ----------------

// Color del chip según el modo de control
Color _modeColor(String mode) {
  switch (mode.toLowerCase()) {
    case 'classic':
      return AppColors.primary;
    case 'voice':
      return Colors.teal;
    case 'imu':
      return Colors.deepPurple;
    default:
      return AppColors.textSecondary;
  }
}

// Formatea una duración como MM:SS o H:MM:SS
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// Formatea metros como "XXX m" o "X.XX km"
String _formatDistance(double meters) {
  if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}

// Formatea una fecha como "15 Apr 2026 · 12:30"
String _formatDate(DateTime dt) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year} · $h:$m';
}

void _downloadFlightPlan(FlightPlan plan) {
  final content = _buildWaypoints(plan);
  final safeName = plan.name
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .replaceAll(' ', '_');
  final filename = 'EZplan_$safeName.waypoints';
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement;
  a.href = url;
  a.download = filename;
  a.click();
  web.URL.revokeObjectURL(url);
}
