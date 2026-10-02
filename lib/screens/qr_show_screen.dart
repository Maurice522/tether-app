import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';
import '../theme/tether_theme.dart';
import '../util/network_info.dart';

/// Shows this device's `address:port` as a QR code — the same payload
/// "Add device by IP" takes as text, just easier to get across a room.
class QrShowScreen extends StatefulWidget {
  const QrShowScreen({super.key});

  @override
  State<QrShowScreen> createState() => _QrShowScreenState();
}

class _QrShowScreenState extends State<QrShowScreen> {
  String? _address;

  @override
  void initState() {
    super.initState();
    primaryLanAddress().then((address) {
      if (mounted) setState(() => _address = address);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final port = context.watch<AppState>().serverPort;
    final address = _address;

    return Scaffold(
      appBar: AppBar(title: const Text('My QR Code')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: address == null
              ? CircularProgressIndicator(color: colors.accentText)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                      child: QrImageView(
                        data: '$address:$port',
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '$address:$port',
                      style: const TextStyle(fontFamily: 'Geist Mono', fontSize: 14),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'On the other device, tap the scan icon on Nearby Devices and point its camera here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.muted, fontSize: 12.5, height: 1.4),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
