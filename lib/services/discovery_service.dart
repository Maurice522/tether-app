import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/device.dart';
import '../util/net_log.dart';

/// Discovers peers on the LAN with a small custom UDP broadcast protocol.
///
/// Every device periodically broadcasts an "announce" packet describing
/// itself (id, display name, platform, and the TCP port its transfer
/// server is listening on). Anyone who hears an announce adds/refreshes
/// that peer in [devices]; peers that haven't announced in a while are
/// dropped. This avoids relying on per-platform mDNS/Bonjour plugins,
/// whose support (especially on Windows) is inconsistent — plain UDP
/// sockets behave the same on macOS, Windows, and Android.
class DiscoveryService {
  static const int discoveryPort = 57891;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration deviceTimeout = Duration(seconds: 11);

  final String selfId;
  String selfName;
  final int Function() httpPort;
  final String platform;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;

  final Map<String, Device> _devices = {};
  final StreamController<List<Device>> _controller = StreamController<List<Device>>.broadcast();

  DiscoveryService({
    required this.selfId,
    required this.selfName,
    required this.httpPort,
    this.platform = 'unknown',
  });

  Stream<List<Device>> get devicesStream => _controller.stream;

  List<Device> get devices => _devices.values.toList(growable: false)
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
    _socket!.broadcastEnabled = true;
    _socket!.listen(_onEvent, onError: (_) {});
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    _cleanupTimer = Timer.periodic(const Duration(seconds: 2), (_) => _cleanupStale());
    _announce();
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _sendPacket({'v': 1, 'type': 'bye', 'id': selfId});
    _socket?.close();
    _socket = null;
    await _controller.close();
  }

  /// Re-announces immediately, e.g. after the local display name changes.
  void refreshSelf({String? name}) {
    if (name != null) selfName = name;
    _announce();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'] as String?;
    if (id == null || id == selfId) return;

    final type = msg['type'] as String?;
    if (type == 'announce') {
      final name = msg['name'] as String?;
      final port = msg['port'] as int?;
      if (name == null || port == null) return;
      final isNew = !_devices.containsKey(id);
      final changedPort = _devices[id]?.port != port;
      _devices[id] = Device(
        id: id,
        name: name,
        platform: msg['platform'] as String? ?? 'unknown',
        address: datagram.address.address,
        port: port,
        lastSeen: DateTime.now(),
      );
      if (isNew || changedPort) {
        netLog('discovery', 'saw $name ($id) at ${datagram.address.address}:$port'
            '${isNew ? ' (new)' : ' (port changed)'}');
      }
      _emit();
    } else if (type == 'bye') {
      if (_devices.remove(id) != null) {
        netLog('discovery', 'bye from $id');
        _emit();
      }
    }
  }

  void _announce() {
    final port = httpPort();
    if (port == 0) {
      netLog('discovery', 'WARNING: announcing with port=0 — transfer server not ready yet');
    }
    _sendPacket({
      'v': 1,
      'type': 'announce',
      'id': selfId,
      'name': selfName,
      'platform': platform,
      'port': port,
    });
  }

  void _sendPacket(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    final bytes = utf8.encode(jsonEncode(payload));
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {
      // Best-effort; a dropped broadcast just means we retry on the next tick.
    }
  }

  void _cleanupStale() {
    final cutoff = DateTime.now().subtract(deviceTimeout);
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emit();
  }

  void _emit() => _controller.add(devices);
}
