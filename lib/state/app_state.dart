import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/pairing_request.dart';
import '../models/remote_entry.dart';
import '../models/transfer.dart';
import '../services/desktop_window_service.dart';
import '../services/discovery_service.dart';
import '../services/history_store.dart';
import '../services/manual_device_store.dart';
import '../services/pairing_store.dart';
import '../services/settings_store.dart';
import '../services/transfer_client.dart' show TransferClient, TransferCanceledException;
import '../services/transfer_server.dart';
import '../util/android_quit.dart';
import '../util/net_log.dart';
import '../util/network_info.dart';
import '../util/pairing_code.dart';
import '../util/save_path.dart';

const _uuid = Uuid();

/// Single source of truth for the UI: wires discovery, the transfer
/// server/client, and persisted settings/trust/history together, and
/// exposes everything the screens need as observable state.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final DesktopWindowService? desktopWindow;

  AppState({this.desktopWindow});

  late final SettingsStore settings;
  late final PairingStore pairing;
  late final HistoryStore history;
  late final ManualDeviceStore manualDevices;

  DiscoveryService? _discovery;
  TransferServer? _server;
  final TransferClient _client = TransferClient();

  List<Device> _discoveredDevices = [];
  final Map<String, Device> _manualDevices = {};
  String? manualAddError;

  /// Broadcast-discovered devices merged with manually-added ones (a
  /// fallback for when broadcast isn't reaching a peer — see
  /// [addManualDevice]). A device discovered normally takes precedence
  /// over a manual entry with the same id, since it's more likely to have
  /// a fresh address/port.
  List<Device> get devices {
    final merged = <String, Device>{..._manualDevices};
    for (final d in _discoveredDevices) {
      merged[d.id] = d;
    }
    return merged.values.toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  final List<IncomingTransferRequest> pendingRequests = [];
  final List<IncomingPairRequest> pendingPairRequests = [];
  final Map<String, TransferRecord> activeTransfers = {};
  List<TransferRecord> completedTransfers = [];
  final Map<String, PairingAttempt> pairingAttempts = {};
  final Map<String, void Function()> _cancelHandlers = {};

  Timer? _clipboardTimer;
  String? _lastClipboardText;
  String? clipboardSyncError;

  Timer? _manualDeviceRefreshTimer;
  bool _resolvingManualDevices = false;

  StreamSubscription<List<Device>>? _devicesSub;
  bool _ready = false;
  bool get ready => _ready;

  /// Set if the server or discovery failed to start. The app still opens
  /// normally either way — [_ready] is never left permanently false just
  /// because one subsystem had a problem — but this surfaces the error
  /// instead of leaving the user staring at an empty, unexplained list.
  String? startupError;

  Future<void> init() async {
    final defaultName = await _defaultDeviceName();
    final defaultDir = await defaultDownloadDir();

    settings = await SettingsStore.load(defaultName: defaultName, defaultDownloadDir: defaultDir);
    pairing = await PairingStore.load();
    history = await HistoryStore.load();
    completedTransfers = history.readAll();
    manualDevices = await ManualDeviceStore.load();
    for (final device in manualDevices.all) {
      _manualDevices[device.id] = device;
    }

    final server = TransferServer(
      onIncomingRequest: _onIncomingRequest,
      onIncomingPairRequest: _onIncomingPairRequest,
      onFileSink: _saveIncomingFile,
      isTrusted: (id) => pairing.isTrusted(id),
      onListDir: _listRemoteDir,
      onOpenFile: _openRemoteFile,
      onClipboard: _onClipboardReceived,
      selfId: settings.deviceId,
      selfName: () => settings.deviceName,
      selfPlatform: _platformLabel(),
    );
    try {
      await server.start();
      _server = server;
    } catch (e, st) {
      netLog('app', 'FATAL: transfer server failed to start: $e\n$st');
      startupError = 'Could not start the transfer server: $e';
    }

    if (_server != null) {
      final discovery = DiscoveryService(
        selfId: settings.deviceId,
        selfName: settings.deviceName,
        httpPort: () => _server!.port,
        platform: _platformLabel(),
      );
      _devicesSub = discovery.devicesStream.listen((list) {
        _discoveredDevices = list;
        notifyListeners();
      });
      try {
        await discovery.start();
        _discovery = discovery;
      } catch (e, st) {
        netLog('app', 'FATAL: discovery failed to start: $e\n$st');
        startupError = 'Could not start device discovery: $e';
      }
    }

    // Always reach "ready" — a broken subsystem should surface as a visible
    // error the user can report, never as an infinite loading spinner with
    // no explanation, which is indistinguishable from "just not working."
    _ready = true;
    notifyListeners();
    _restartClipboardSync();
    WidgetsBinding.instance.addObserver(this);

    _resolveManualDevices();
    _manualDeviceRefreshTimer = Timer.periodic(_manualDeviceRefreshInterval, (_) => _resolveManualDevices());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _devicesSub?.cancel();
    _discovery?.stop();
    _server?.stop();
    _clipboardTimer?.cancel();
    _manualDeviceRefreshTimer?.cancel();
    super.dispose();
  }

  /// Fully quits the app on Android: closing the window there only
  /// backgrounds it (by design — the foreground service keeps discovery,
  /// the transfer server, and clipboard sync running so other devices can
  /// still reach you), so a deliberate quit needs its own explicit
  /// action, same as the desktop tray's separate Show/Quit. Stops
  /// discovery and the server first so peers see a clean "bye" instead of
  /// this device just timing out, then tells the native side to stop the
  /// foreground service and terminate the process.
  Future<void> quitApp() async {
    netLog('app', 'quitting: stopping discovery and server');
    _clipboardTimer?.cancel();
    _manualDeviceRefreshTimer?.cancel();
    await _discovery?.stop();
    await _server?.stop();
    if (Platform.isAndroid) {
      await quitAndroidApp();
    }
  }

  /// Android blocks a backgrounded app from reading the system clipboard
  /// at all, so the periodic poll may have spent the whole time in the
  /// background silently seeing a stale/blocked read — it can't detect a
  /// copy made while unfocused no matter how often it ticks. As soon as
  /// the app is focused again, force an immediate check instead of
  /// waiting up to [_clipboardPollInterval] for the next scheduled tick.
  ///
  /// Also re-announces discovery immediately: an OEM battery manager can
  /// throttle a backgrounded app's own outgoing broadcast even with the
  /// foreground service running, so this device may have quietly dropped
  /// out of everyone else's Nearby Devices list. Nothing the *other* side
  /// does (including hitting refresh) can fix that — only this device
  /// broadcasting again can — so do it the moment it's foregrounded
  /// rather than waiting for the next scheduled tick.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _discovery?.refreshSelf();
      _pollClipboard();
      _resolveManualDevices();
    }
  }

  /// Re-broadcasts a discovery announce right now instead of waiting for
  /// the next periodic tick, and prunes any devices already gone stale —
  /// backs the pull-to-refresh / refresh button on the Nearby screen.
  void refreshDevices() {
    _discovery?.refreshSelf();
  }

  void dismissStartupError() {
    startupError = null;
    notifyListeners();
  }

  /// Fallback for when broadcast discovery isn't reaching a peer (e.g. a
  /// router that filters broadcast/multicast between Wi-Fi clients while
  /// unicast still works fine — the actual cause is unfixable from here,
  /// this just routes around it): probes [address] directly and adds
  /// whatever answers as a device, exactly as if discovery had found it.
  Future<void> addManualDevice(String address) async {
    manualAddError = null;
    notifyListeners();
    try {
      final device = await _client.probeDevice(address: address);
      _manualDevices[device.id] = device;
      await manualDevices.remember(device);
    } catch (e) {
      manualAddError = 'Could not reach $address: $e';
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Manual device auto-reconnect
  //
  // A manually-added device's IP can drift (DHCP lease renewal, the
  // router restarting, etc.) — there's no MAC-address-to-IP lookup
  // available to us that works across platforms (no generic router API
  // exists, and Android specifically blocks apps from reading the ARP
  // table or doing raw network scans, for the same reason it blocks
  // background clipboard reads: that access is exactly what malware
  // wants). Instead, this uses our own protocol to get the same result:
  // sweep the local /24 asking each address "who are you" and see which
  // one answers with the id we already know. Works identically on every
  // platform since it's just ordinary HTTP requests, no special
  // permissions needed.
  // ---------------------------------------------------------------------

  static const Duration _manualDeviceRefreshInterval = Duration(seconds: 45);
  static const Duration _manualDeviceQuickCheckTimeout = Duration(seconds: 3);
  static const Duration _subnetSweepTimeout = Duration(milliseconds: 500);

  /// Re-checks every manually-added device not already found by broadcast
  /// discovery (no need to fix what isn't broken) — cheap in the common
  /// case (one quick request per device against its last-known address),
  /// only falling back to a full subnet sweep when that address stops
  /// answering as the expected device.
  Future<void> _resolveManualDevices() async {
    if (_resolvingManualDevices) return; // previous sweep still running; don't overlap
    final stale = _manualDevices.values
        .where((d) => !_discoveredDevices.any((discovered) => discovered.id == d.id))
        .toList();
    if (stale.isEmpty) return;

    _resolvingManualDevices = true;
    try {
      for (final device in stale) {
        await _resolveManualDevice(device);
      }
    } finally {
      _resolvingManualDevices = false;
    }
  }

  Future<void> _resolveManualDevice(Device knownDevice) async {
    try {
      final probed = await _client.probeDevice(
        address: knownDevice.address,
        port: knownDevice.port,
        timeout: _manualDeviceQuickCheckTimeout,
        quiet: true,
      );
      if (probed.id == knownDevice.id) return; // still at the same address, nothing to do
      // Something else now answers at that address; the real device has
      // moved. Fall through to find where.
    } catch (_) {
      // Unreachable at the last-known address; fall through to a sweep.
    }

    final found = await _scanSubnetFor(knownDevice.id, excludeAddress: knownDevice.address);
    if (found == null) return; // not found this round; the periodic timer will try again

    netLog('app', 'manual device ${knownDevice.name} moved ${knownDevice.address} -> ${found.address}');
    _manualDevices[found.id] = found;
    await manualDevices.remember(found);
    notifyListeners();
  }

  /// Probes every address in this device's own /24 (in parallel, short
  /// timeout each) for [targetId], skipping [excludeAddress] since that's
  /// already known to have failed. Returns the matching device, or null
  /// if nothing on the subnet currently claims that id.
  Future<Device?> _scanSubnetFor(String targetId, {String? excludeAddress}) async {
    // A phone with mobile data on alongside Wi-Fi also carries a
    // carrier-NAT address that isn't part of the LAN at all — sweeping
    // that subnet instead of the real one silently finds nothing.
    final myIp = await primaryLanAddress();
    if (myIp == null) return null;
    final parts = myIp.split('.');
    if (parts.length != 4) return null;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    final candidates = [for (var i = 1; i <= 254; i++) '$prefix.$i']
      ..removeWhere((ip) => ip == excludeAddress || ip == myIp);

    final results = await Future.wait(
      candidates.map((ip) async {
        try {
          return await _client.probeDevice(address: ip, timeout: _subnetSweepTimeout, quiet: true);
        } catch (_) {
          return null;
        }
      }),
    );

    for (final device in results) {
      if (device != null && device.id == targetId) return device;
    }
    return null;
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

  Future<void> _bringToFront() async {
    try {
      await desktopWindow?.bringToFront();
    } catch (_) {
      // Best-effort; never let a window-focus hiccup block an incoming request.
    }
  }

  // ---------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------

  /// Starts pairing with [target]: shows a code locally and sends a pair
  /// request the other device must confirm. On mutual acceptance, both
  /// sides trust each other and future transfers need no further prompts.
  /// Returns an id to watch via [pairingAttempts].
  String initiatePairing(Device target) {
    final id = _uuid.v4();
    final code = generatePairingCode();
    final attempt = PairingAttempt(id: id, peerId: target.id, peerName: target.name, code: code);
    pairingAttempts[id] = attempt;
    notifyListeners();

    _runOutgoingPairing(target, attempt);
    return id;
  }

  Future<void> _runOutgoingPairing(Device target, PairingAttempt attempt) async {
    try {
      final accepted = await _client.sendPairRequest(
        target: target,
        selfId: settings.deviceId,
        selfName: settings.deviceName,
        code: attempt.code,
      );
      if (accepted) {
        await pairing.trust(target.id, target.name);
        attempt.status = PairingStatus.accepted;
      } else {
        attempt.status = PairingStatus.declined;
      }
    } catch (e) {
      attempt.status = PairingStatus.failed;
      attempt.error = e.toString();
    }
    notifyListeners();
  }

  void _onIncomingPairRequest(IncomingPairRequest request) {
    pendingPairRequests.add(request);
    _bringToFront();
    notifyListeners();
  }

  Future<void> respondToPairRequest(IncomingPairRequest request, bool accept) async {
    pendingPairRequests.remove(request);
    if (accept) {
      await pairing.trust(request.requesterId, request.requesterName);
    }
    request.decision.complete(accept);
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
    var canceled = false;
    _cancelHandlers[record.id] = () => canceled = true;
    netLog('app', 'sending ${record.id} to ${target.name} (${target.address}:${target.port}), '
        '${files.length} file(s)');

    try {
      final result = await _client.sendOffer(
        target: target,
        selfId: settings.deviceId,
        selfName: settings.deviceName,
        transferId: record.id,
        files: fileMetas,
        pairingCode: code,
      );

      if (canceled) throw const TransferCanceledException();

      if (!result.accepted) {
        netLog('app', '${record.id} declined by ${target.name}');
        record.status = TransferStatus.declined;
        await _finishRecord(record);
        return;
      }

      record.status = TransferStatus.transferring;
      notifyListeners();

      var bytesBeforeCurrentFile = 0;
      for (var i = 0; i < files.length; i++) {
        if (canceled) throw const TransferCanceledException();
        await _client.uploadFile(
          target: target,
          transferId: record.id,
          fileIndex: i,
          file: files[i],
          isCanceled: () => canceled,
          onProgress: (sent, total) {
            record.bytesTransferred = bytesBeforeCurrentFile + sent;
            notifyListeners();
          },
        );
        bytesBeforeCurrentFile += fileMetas[i].size;
      }
      record.status = TransferStatus.completed;
      netLog('app', '${record.id} completed');
    } catch (e) {
      netLog('app', '${record.id} failed/canceled: $e');
      record.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
      if (!canceled) record.error = e.toString();
    }
    _cancelHandlers.remove(record.id);
    await _finishRecord(record);
  }

  // ---------------------------------------------------------------------
  // Incoming transfers
  // ---------------------------------------------------------------------

  void _onIncomingRequest(IncomingTransferRequest request) {
    netLog('app', 'incoming request ${request.transferId} from ${request.senderName} '
        '(${request.senderAddress}), trusted=${pairing.isTrusted(request.senderId)}');
    if (pairing.isTrusted(request.senderId)) {
      _acceptIncoming(request, trustAfter: false);
      return;
    }
    pendingRequests.add(request);
    _bringToFront();
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

  /// How long an active transfer may go without any bytes arriving before
  /// it's automatically failed — otherwise a dropped connection (Wi-Fi
  /// hiccup, peer app closed) leaves the UI stuck on "In progress" forever
  /// with no feedback and no way out.
  static const Duration _stallTimeout = Duration(seconds: 20);

  Future<void> _saveIncomingFile(
    IncomingTransferRequest request,
    int fileIndex,
    FileMeta meta,
    Stream<List<int>> data,
  ) async {
    final record = activeTransfers[request.transferId];
    final bytesBeforeCurrentFile = request.files.sublist(0, fileIndex).fold<int>(0, (s, f) => s + f.size);
    final savePath = await uniqueSavePath(settings.downloadDir, meta.name);
    netLog('app', 'saving incoming ${request.transferId} file $fileIndex (${meta.name}, ${meta.size}b) -> $savePath');
    final sink = File(savePath).openWrite();

    var received = 0;
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = data.timeout(_stallTimeout).listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (record != null) {
          record.bytesTransferred = bytesBeforeCurrentFile + received;
          notifyListeners();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );
    _cancelHandlers[request.transferId] = () {
      sub.cancel();
      if (!completer.isCompleted) completer.completeError(const TransferCanceledException());
    };

    try {
      await completer.future;
      await sink.flush();
      await sink.close();
      netLog('app', 'incoming ${request.transferId} file $fileIndex saved, $received bytes received');
      record?.savedPaths.add(savePath);

      if (record != null && fileIndex == request.files.length - 1) {
        record.status = TransferStatus.completed;
        await _finishRecord(record);
      }
    } catch (e) {
      netLog('app', 'incoming ${request.transferId} file $fileIndex errored after $received/$bytesBeforeCurrentFile+'
          '${meta.size} bytes: $e');
      await sink.close();
      if (record != null) {
        final canceled = e is TransferCanceledException;
        record.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
        if (!canceled) record.error = e is TimeoutException ? 'Connection stalled — no data received' : e.toString();
        await _finishRecord(record);
      }
      rethrow;
    } finally {
      _cancelHandlers.remove(request.transferId);
    }
  }

  /// Cancels an active transfer, best-effort: stops an in-progress upload
  /// (outgoing) or download (incoming) as soon as the running loop notices,
  /// or finalizes immediately if nothing is actively streaming yet.
  void cancelTransfer(String transferId) {
    final handler = _cancelHandlers.remove(transferId);
    if (handler != null) {
      handler();
      return;
    }
    final record = activeTransfers[transferId];
    if (record != null) {
      record.status = TransferStatus.canceled;
      _finishRecord(record);
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
  // Remote browsing
  //
  // A paired device can browse the *shared folder* (the same folder
  // incoming transfers are saved into) of another paired device, and pull
  // files from it directly — no per-file prompt, since pairing is already
  // the trust boundary. This intentionally does not expose the whole
  // filesystem: the shared folder is the only root, both because a
  // sandboxed macOS build has no broader file access without the user
  // granting it per-folder, and because a fixed root keeps the feature's
  // blast radius obvious and bounded.
  // ---------------------------------------------------------------------

  /// Lists the immediate children of [path] ("" for the root) in a peer's
  /// shared folder.
  Future<List<RemoteEntry>> browseDevice(Device device, String path) {
    return _client.browse(target: device, requesterId: settings.deviceId, path: path);
  }

  /// Starts downloading [entry] (found at [parentPath] in [device]'s shared
  /// folder) into this device's own shared folder. Returns immediately with
  /// a transfer id; progress/outcome show up in [activeTransfers] /
  /// [completedTransfers] exactly like any other incoming transfer.
  String startDownload(Device device, RemoteEntry entry, String parentPath) {
    final transferId = _uuid.v4();
    final record = TransferRecord(
      id: transferId,
      direction: TransferDirection.incoming,
      peerName: device.name,
      peerId: device.id,
      files: [FileMeta(name: entry.name, size: entry.size)],
      status: TransferStatus.transferring,
    );
    activeTransfers[transferId] = record;
    notifyListeners();

    _runBrowseDownload(device, entry, parentPath, record);
    return transferId;
  }

  Future<void> _runBrowseDownload(
    Device device,
    RemoteEntry entry,
    String parentPath,
    TransferRecord record,
  ) async {
    var canceled = false;
    _cancelHandlers[record.id] = () => canceled = true;
    final remotePath = parentPath.isEmpty ? entry.name : '$parentPath/${entry.name}';
    netLog('app', 'downloading "$remotePath" from ${device.name} (${record.id})');

    try {
      final savePath = await uniqueSavePath(settings.downloadDir, entry.name);
      await _client.fetchFile(
        target: device,
        requesterId: settings.deviceId,
        remotePath: remotePath,
        savePath: savePath,
        isCanceled: () => canceled,
        onProgress: (received, total) {
          record.bytesTransferred = received;
          notifyListeners();
        },
      );
      record.status = TransferStatus.completed;
      record.savedPaths.add(savePath);
      netLog('app', 'download ${record.id} completed');
    } catch (e) {
      netLog('app', 'download ${record.id} failed/canceled: $e');
      record.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
      if (!canceled) record.error = e.toString();
    }
    _cancelHandlers.remove(record.id);
    await _finishRecord(record);
  }

  /// Resolves a "/"-separated relative path against the shared folder,
  /// rejecting anything that would escape it (no "..", no absolute paths).
  String _resolveSharedPath(String relativePath) {
    final segments = relativePath.split('/').where((s) => s.isNotEmpty);
    if (segments.any((s) => s == '.' || s == '..')) {
      throw Exception('Invalid path');
    }
    final root = p.normalize(settings.downloadDir);
    final resolved = p.normalize(p.joinAll([root, ...segments]));
    if (resolved != root && !p.isWithin(root, resolved)) {
      throw Exception('Invalid path');
    }
    return resolved;
  }

  Future<List<RemoteEntry>> _listRemoteDir(String relativePath) async {
    final dirPath = _resolveSharedPath(relativePath);
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final entries = <RemoteEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final stat = await entity.stat();
      entries.add(RemoteEntry(
        name: p.basename(entity.path),
        isDir: entity is Directory,
        size: entity is File ? stat.size : 0,
        modified: stat.modified,
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  File _openRemoteFile(String relativePath) {
    return File(_resolveSharedPath(relativePath));
  }

  // ---------------------------------------------------------------------
  // Clipboard sync
  //
  // While enabled, polls the local clipboard every couple seconds and
  // pushes any change to the chosen paired device, and applies whatever
  // that device pushes back here — a two-way sync with no per-copy
  // prompt, same trust boundary as browsing/sending. Polling (rather than
  // a native "clipboard changed" listener) is deliberate: it's plain
  // Dart, so it behaves identically on macOS/Windows/Android without
  // adding another native plugin to a toolchain we can't build-test for
  // Windows here.
  //
  // Caveat that no amount of extra code here can remove: Android 10+
  // blocks any app from reading the system clipboard while it isn't the
  // focused foreground app (a deliberate OS privacy rule against silent
  // clipboard snooping). So on Android this device can only *detect* a
  // new copy while Tether is actually open and in front; it can still
  // *receive* a push from the other device and apply it any time this
  // app's process is alive.
  // ---------------------------------------------------------------------

  static const Duration _clipboardPollInterval = Duration(seconds: 2);

  /// Turns clipboard sync with [deviceId] on or off and persists the
  /// choice. Pass `null` for [deviceId] to just persist the enabled flag
  /// (e.g. re-enabling after it was already configured).
  Future<void> setClipboardSync({required bool enabled, String? deviceId}) async {
    await settings.setClipboardSyncEnabled(enabled);
    if (deviceId != null) await settings.setClipboardSyncDeviceId(deviceId);
    clipboardSyncError = null;
    _restartClipboardSync();
    notifyListeners();
  }

  void _restartClipboardSync() {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
    if (!settings.clipboardSyncEnabled || settings.clipboardSyncDeviceId == null) return;
    _lastClipboardText = null;
    _clipboardTimer = Timer.periodic(_clipboardPollInterval, (_) => _pollClipboard());
  }

  Future<void> _pollClipboard() async {
    final targetId = settings.clipboardSyncDeviceId;
    if (targetId == null) return;
    final matches = devices.where((d) => d.id == targetId);
    if (matches.isEmpty) {
      // Sync partner not currently in the discovered-devices list (out of
      // range, Wi-Fi off, or its app isn't running) — surface that instead
      // of silently doing nothing, and try again next tick.
      final name = pairing.nameFor(targetId) ?? 'the paired device';
      if (clipboardSyncError != '$name is offline') {
        clipboardSyncError = '$name is offline';
        notifyListeners();
      }
      return;
    }
    final target = matches.first;

    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (e) {
      netLog('app', 'clipboard read failed: $e');
      return;
    }
    if (text == null || text.isEmpty || text == _lastClipboardText) return;
    netLog('app', 'clipboard changed locally (${text.length} chars), pushing to ${target.name}');

    try {
      await _client.sendClipboard(target: target, requesterId: settings.deviceId, text: text);
      // Only mark as delivered once the push actually succeeds — otherwise
      // a single transient failure (peer briefly unreachable, e.g. right
      // after toggling sync on) would silently mark this text as already
      // synced and it would never be retried, even though the peer never
      // got it.
      _lastClipboardText = text;
      netLog('app', 'clipboard pushed to ${target.name} OK');
      if (clipboardSyncError != null) {
        clipboardSyncError = null;
        notifyListeners();
      }
    } catch (e) {
      netLog('app', 'clipboard push to ${target.name} failed: $e');
      clipboardSyncError = 'Could not reach ${target.name}';
      notifyListeners();
    }
  }

  void _onClipboardReceived(String text) {
    if (!settings.clipboardSyncEnabled) return;
    if (text.isEmpty || text == _lastClipboardText) return;
    _lastClipboardText = text;
    netLog('app', 'applying clipboard push (${text.length} chars)');
    Clipboard.setData(ClipboardData(text: text));
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
      // Android commonly reports the literal string "localhost" rather
      // than throwing or returning empty — not a real hostname, so treat
      // it the same as unavailable rather than showing it to the user.
      if (host.isNotEmpty && host.toLowerCase() != 'localhost') return host;
    } catch (_) {
      // Not available on some platforms/sandboxes; fall through.
    }
    return 'My ${_platformLabel()} device';
  }
}
