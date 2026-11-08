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
  bool _stopped = false;
  bool _rebinding = false;

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
    _stopped = false;
    await _bind();
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    _cleanupTimer = Timer.periodic(const Duration(seconds: 2), (_) => _cleanupStale());
    _announce();
  }

  Future<void> _bind() async {
    // SO_REUSEADDR alone doesn't let two sockets share a UDP port on
    // Apple platforms — that needs SO_REUSEPORT too (unsupported on
    // Windows/Android). Matters when two Tether instances share one
    // network stack, e.g. the iOS simulator running beside the Mac app.
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: Platform.isMacOS || Platform.isIOS || Platform.isLinux,
    );
    _socket!.broadcastEnabled = true;
    _socket!.listen(_onEvent, onError: (e) {
      netLog('discovery', 'socket error: $e — attempting to rebind');
      _rebind();
    });
  }

  /// A bound UDP socket can error out from underneath us (Wi-Fi toggled,
  /// network interface changed) — without this, discovery would silently
  /// and permanently stop for the rest of the app's lifetime with no way
  /// to recover short of a full restart.
  Future<void> _rebind() async {
    if (_stopped || _rebinding) return;
    _rebinding = true;
    try {
      _socket?.close();
      _socket = null;
      await _bind();
      netLog('discovery', 'rebind succeeded');
      _announce();
    } catch (e) {
      netLog('discovery', 'rebind failed: $e — discovery inactive until the app restarts');
    } finally {
      _rebinding = false;
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _sendPacket({'v': 1, 'type': 'bye', 'id': selfId});
    _socket?.close();
    _socket = null;
    await _controller.close();
  }

  /// Re-announces immediately, e.g. after the local display name changes,
  /// and asks every other peer within earshot to do the same right now
  /// instead of waiting for their next periodic tick — otherwise a manual
  /// refresh can't do anything for *this* device's own list, only make
  /// others notice this device sooner.
  void refreshSelf({String? name}) {
    if (name != null) selfName = name;
    _announce();
    _sendPacket({'v': 1, 'type': 'ping', 'id': selfId});
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
    } else if (type == 'ping') {
      _announce();
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
