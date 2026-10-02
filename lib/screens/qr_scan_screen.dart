import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import 'widgets/pairing_dialog.dart';

enum _PermissionState { checking, granted, denied, permanentlyDenied }

/// Scans another device's "My QR Code" and starts pairing with it —
/// Android only (no `ios/` directory exists in this project, and desktop
/// QR camera-scanning support is comparatively immature).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  _PermissionState _permission = _PermissionState.checking;
  bool _processing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _requestPermission();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _requestPermission() async {
    setState(() => _permission = _PermissionState.checking);
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permission = status.isGranted
          ? _PermissionState.granted
          : status.isPermanentlyDenied
              ? _PermissionState.permanentlyDenied
              : _PermissionState.denied;
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;

    final sep = raw.lastIndexOf(':');
    final port = sep == -1 ? null : int.tryParse(raw.substring(sep + 1));
    final address = sep == -1 ? null : raw.substring(0, sep);
    if (address == null || address.isEmpty || port == null) {
      setState(() => _error = "That doesn't look like a Tether QR code.");
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final attemptId = await context.read<AppState>().pairByAddress(address, port);
      if (!mounted) return;
      Navigator.of(context).pop();
      showDialog(context: context, builder: (_) => PairingDialog(attemptId: attemptId));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Could not reach $address: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: switch (_permission) {
        _PermissionState.checking => Center(child: CircularProgressIndicator(color: colors.accentText)),
        _PermissionState.granted => Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(controller: _controller, onDetect: _onDetect),
              if (_processing)
                Container(
                  color: Colors.black45,
                  child: Center(child: CircularProgressIndicator(color: colors.accentText)),
                ),
              if (_error != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Material(
                    color: colors.danger,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!, style: const TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
            ],
          ),
        _PermissionState.denied || _PermissionState.permanentlyDenied => _PermissionDeniedMessage(
            permanentlyDenied: _permission == _PermissionState.permanentlyDenied,
            onRetry: _requestPermission,
          ),
      },
    );
  }
}

class _PermissionDeniedMessage extends StatelessWidget {
  final bool permanentlyDenied;
  final VoidCallback onRetry;

  const _PermissionDeniedMessage({required this.permanentlyDenied, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_rounded, size: 40, color: colors.faint),
            const SizedBox(height: 16),
            Text(
              'Tether needs camera access to scan a QR code.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: permanentlyDenied ? openAppSettings : onRetry,
              child: Text(permanentlyDenied ? 'Open Settings' : 'Grant Camera Access'),
            ),
          ],
        ),
      ),
    );
  }
}
