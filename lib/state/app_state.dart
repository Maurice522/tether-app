import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/transfer.dart';
import '../services/discovery_service.dart';
import '../services/history_store.dart';
import '../services/pairing_store.dart';
import '../services/settings_store.dart';
import '../services/transfer_client.dart';
import '../services/transfer_server.dart';
import '../util/pairing_code.dart';
import '../util/save_path.dart';

const _uuid = Uuid();

/// Single source of truth for the UI: wires discovery, the transfer
/// server/client, and persisted settings/trust/history together, and
/// exposes everything the screens need as observable state.
class AppState extends ChangeNotifier {
  late final SettingsStore settings;
  late final PairingStore pairing;
  late final HistoryStore history;

  DiscoveryService? _discovery;
  TransferServer? _server;
  final TransferClient _client = TransferClient();

  List<Device> devices = [];
  final List<IncomingTransferRequest> pendingRequests = [];
  final Map<String, TransferRecord> activeTransfers = {};
  List<TransferRecord> completedTransfers = [];

  StreamSubscription<List<Device>>? _devicesSub;
  bool _ready = false;
  bool get ready => _ready;

  Future<void> init() async {
    final defaultName = await _defaultDeviceName();
    final defaultDir = await defaultDownloadDir();

    settings = await SettingsStore.load(defaultName: defaultName, defaultDownloadDir: defaultDir);
    pairing = await PairingStore.load();
    history = await HistoryStore.load();
    completedTransfers = history.readAll();

    final server = TransferServer(onIncomingRequest: _onIncomingRequest, onFileSink: _saveIncomingFile);
    await server.start();
    _server = server;

    final discovery = DiscoveryService(
      selfId: settings.deviceId,
      selfName: settings.deviceName,
      httpPort: () => server.port,
      platform: _platformLabel(),
    );
    _devicesSub = discovery.devicesStream.listen((list) {
      devices = list;
      notifyListeners();
    });
    await discovery.start();
    _discovery = discovery;

    _ready = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _discovery?.stop();
    _server?.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------

  Future<void> updateDeviceName(String name) async {
    await settings.setDeviceName(name);
    _discovery?.refreshSelf(name: name);
    notifyListeners();
  }

  Future<void> updateDownloadDir(String path) async {
    await settings.setDownloadDir(path);
    notifyListeners();
  }

  Future<void> updateAutoAccept(bool value) async {
    await settings.setAutoAcceptTrusted(value);
    notifyListeners();
  }

  ThemeMode get themeMode {
    if (!_ready) return ThemeMode.system;
    switch (settings.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> updateThemeMode(ThemeMode mode) async {
    await settings.setThemeMode(mode.name);
    notifyListeners();
  }

  Future<void> setTrusted(String deviceId, String name, bool trusted) async {
    if (trusted) {
      await pairing.trust(deviceId, name);
    } else {
      await pairing.untrust(deviceId);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Outgoing transfers
  // ---------------------------------------------------------------------

  /// Kicks off sending [files] to [target] and returns the new transfer's
  /// id immediately (file sizes are read synchronously so the record can
  /// be created and shown in the UI before any network I/O happens). The
  /// offer/upload work continues in the background; observe
  /// [activeTransfers]/[completedTransfers] for progress and outcome.
  String sendFiles(Device target, List<File> files) {
    final transferId = _uuid.v4();
    final fileMetas = files.map((f) => FileMeta(name: p.basename(f.path), size: f.lengthSync())).toList();

    final showPairing = !pairing.isTrusted(target.id);
    final code = generatePairingCode();

    final record = TransferRecord(
      id: transferId,
      direction: TransferDirection.outgoing,
      peerName: target.name,
      peerId: target.id,
      files: fileMetas,
      pairingCode: showPairing ? code : null,
    );
    activeTransfers[transferId] = record;
    notifyListeners();

    _runOutgoingTransfer(target, files, fileMetas, record, code);
    return transferId;
  }

  Future<void> _runOutgoingTransfer(
    Device target,
    List<File> files,
    List<FileMeta> fileMetas,
    TransferRecord record,
    String code,
  ) async {
    try {
      final result = await _client.sendOffer(
        target: target,
        selfId: settings.deviceId,
        selfName: settings.deviceName,
        transferId: record.id,
        files: fileMetas,
        pairingCode: code,
      );

      if (!result.accepted) {
        record.status = TransferStatus.declined;
        await _finishRecord(record);
        return;
      }

      record.status = TransferStatus.transferring;
      notifyListeners();

      var bytesBeforeCurrentFile = 0;
      for (var i = 0; i < files.length; i++) {
        await _client.uploadFile(
          target: target,
          transferId: record.id,
          fileIndex: i,
          file: files[i],
          onProgress: (sent, total) {
            record.bytesTransferred = bytesBeforeCurrentFile + sent;
            notifyListeners();
          },
        );
        bytesBeforeCurrentFile += fileMetas[i].size;
      }
      record.status = TransferStatus.completed;
    } catch (e) {
      record.status = TransferStatus.failed;
      record.error = e.toString();
    }
    await _finishRecord(record);
  }

  // ---------------------------------------------------------------------
  // Incoming transfers
  // ---------------------------------------------------------------------

  void _onIncomingRequest(IncomingTransferRequest request) {
    final autoAccept = settings.autoAcceptTrusted && pairing.isTrusted(request.senderId);
    if (autoAccept) {
      _acceptIncoming(request, trustAfter: false);
      return;
    }
    pendingRequests.add(request);
    notifyListeners();
  }

  bool isSenderTrusted(String senderId) => pairing.isTrusted(senderId);

  Future<void> respondToIncoming(IncomingTransferRequest request, bool accept, {bool trustAfter = false}) async {
    pendingRequests.remove(request);
    notifyListeners();
    if (accept) {
      await _acceptIncoming(request, trustAfter: trustAfter);
    } else {
      request.decision.complete(false);
      final record = TransferRecord(
        id: request.transferId,
        direction: TransferDirection.incoming,
        peerName: request.senderName,
        peerId: request.senderId,
        files: request.files,
        status: TransferStatus.declined,
      );
      await _finishRecord(record);
    }
  }

  Future<void> _acceptIncoming(IncomingTransferRequest request, {required bool trustAfter}) async {
    if (trustAfter) {
      await pairing.trust(request.senderId, request.senderName);
    }
    final record = TransferRecord(
      id: request.transferId,
      direction: TransferDirection.incoming,
      peerName: request.senderName,
      peerId: request.senderId,
      files: request.files,
      status: TransferStatus.transferring,
    );
    activeTransfers[request.transferId] = record;
    notifyListeners();
    request.decision.complete(true);
    // Completion/failure is reported by _saveIncomingFile as bytes arrive;
    // the record above is what the UI observes for progress.
  }

  Future<void> _saveIncomingFile(
    IncomingTransferRequest request,
    int fileIndex,
    FileMeta meta,
    Stream<List<int>> data,
  ) async {
    final record = activeTransfers[request.transferId];
    final bytesBeforeCurrentFile = request.files.sublist(0, fileIndex).fold<int>(0, (s, f) => s + f.size);
    final savePath = await uniqueSavePath(settings.downloadDir, meta.name);
    final sink = File(savePath).openWrite();
    try {
      await for (final chunk in data) {
        sink.add(chunk);
        if (record != null) {
          record.bytesTransferred = bytesBeforeCurrentFile + chunk.length;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();

      if (record != null && fileIndex == request.files.length - 1) {
        record.status = TransferStatus.completed;
        await _finishRecord(record);
      }
    } catch (e) {
      await sink.close();
      if (record != null) {
        record.status = TransferStatus.failed;
        record.error = e.toString();
        await _finishRecord(record);
      }
      rethrow;
    }
  }

  Future<void> _finishRecord(TransferRecord record) async {
    record.finishedAt ??= DateTime.now();
    activeTransfers.remove(record.id);
    completedTransfers.insert(0, record);
    await history.append(record);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await history.clear();
    completedTransfers = [];
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  String _platformLabel() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  Future<String> _defaultDeviceName() async {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty) return host;
    } catch (_) {
      // Not available on some platforms/sandboxes; fall through.
    }
    return 'My ${_platformLabel()} device';
  }
}
