import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
import '../services/cert_manager.dart';
import '../services/desktop_window_service.dart';
import '../services/discovery_service.dart';
import '../services/history_store.dart';
import '../services/manual_device_store.dart';
import '../services/notification_service.dart';
import '../services/pairing_store.dart';
import '../services/settings_store.dart';
import '../services/transfer_client.dart' show TransferClient, TransferCanceledException;
import '../services/transfer_server.dart';
import '../util/android_quit.dart';
import '../util/android_reveal.dart';
import '../util/net_log.dart';
import '../util/network_info.dart';
import '../util/pairing_code.dart';
import '../util/save_path.dart';
import '../util/speed_tracker.dart';

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
  /// The port this device's transfer server is actually listening on —
  /// usually [TransferServer.defaultPort], but can differ if that port was
  /// already taken (see [TransferServer.start]). Used for the QR pairing
  /// payload so scanning it works even in that fallback case, unlike
  /// "Add device by IP" which has to assume the default port.
  int get serverPort => _server?.port ?? TransferServer.defaultPort;

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
  Future<void>? _manualDevicesSweep;
  final Set<String> _finalizedTransferIds = {};

  // ---------------------------------------------------------------------
  // Transfer resume/retry bookkeeping
  // ---------------------------------------------------------------------

  /// Pending manual-retry signals for a [TransferStatus.stalled] transfer
  /// this device actively drives (an outgoing send or a browse download —
  /// never an incoming push, which has nothing of its own to retry). Its
  /// presence for a given transfer id is also what [canRetry] reports.
  final Map<String, Completer<void>> _manualRetryTriggers = {};

  /// Where an incoming file's bytes are being saved, keyed by
  /// `'<transferId>#<fileIndex>'` — remembered across a stall so a resumed
  /// upload appends to the same file instead of starting a new one, and so
  /// [_uploadStatusFor] can report how much of it already arrived.
  final Map<String, String> _incomingFilePaths = {};

  /// How long an incoming (pushed) transfer waits, once stalled, for the
  /// sender to resume it before giving up for good. Deliberately longer
  /// than a sender's own bounded automatic retries (a few seconds) so
  /// those always get a chance to land — the receiver has no retry action
  /// of its own, so this is the only thing standing between "briefly
  /// stalled" and "stuck forever" for a sender that never comes back.
  static const Duration _incomingResumeTimeout = Duration(seconds: 30);
  final Map<String, Timer> _incomingStallTimers = {};

  static const List<Duration> _retryBackoffs = [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 8)];

  NotificationService? _notifications;

  /// Set by [requestTab] (currently only from a tapped transfer
  /// notification, jumping to the Activity tab) and consumed once by
  /// whichever widget owns the actual tab index — see
  /// [consumeRequestedTab]. Durable rather than a one-shot event stream so
  /// it isn't lost if the request arrives before that widget exists yet
  /// (e.g. the app was launched fresh by tapping the notification).
  int? requestedTab;

  void requestTab(int index) {
    requestedTab = index;
    notifyListeners();
  }

  int? consumeRequestedTab() {
    final tab = requestedTab;
    requestedTab = null;
    return tab;
  }

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

    final certManager = await CertManager.load();

    final server = TransferServer(
      onIncomingRequest: _onIncomingRequest,
      onIncomingPairRequest: _onIncomingPairRequest,
      onFileSink: _saveIncomingFile,
      onUploadStatus: _uploadStatusFor,
      isTrusted: (id) => pairing.isTrusted(id),
      onListDir: _listRemoteDir,
      onOpenFile: _openRemoteFile,
      onClipboard: _onClipboardReceived,
      onUnpairHint: _onUnpairHint,
      selfId: settings.deviceId,
      selfName: () => settings.deviceName,
      selfPlatform: _platformLabel(),
      securityContext: certManager.securityContext,
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
        final known = _discoveredDevices.map((d) => d.id).toSet();
        _discoveredDevices = list;
        notifyListeners();
        // A device showing up (or coming back) is the moment to find out
        // whether it unpaired us while we weren't looking.
        for (final device in list) {
          if (!known.contains(device.id)) reconcileTrust(device);
        }
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

    // Not awaited: a slow/blocked permission prompt (macOS/Android) should
    // never hold up reaching "ready" above.
    final notifications = NotificationService();
    _notifications = notifications;
    notifications.init(onTapped: () => requestTab(2)); // 2 == Activity tab in HomeScreen._screens

    _syncAndroidDownloadDir();
    // Delayed so this system screen doesn't land on top of the
    // notification-permission prompt that startup is also showing.
    Future<void>.delayed(const Duration(seconds: 6), () => _syncAndroidDownloadDir(promptOnce: true));
    _resolveManualDevices();
    _manualDeviceRefreshTimer = Timer.periodic(_manualDeviceRefreshInterval, (_) => _resolveManualDevices());
    _trustSweepTimer = Timer.periodic(_trustSweepInterval, (_) {
      for (final device in devices) {
        reconcileTrust(device);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _devicesSub?.cancel();
    _discovery?.stop();
    _server?.stop();
    _clipboardTimer?.cancel();
    _manualDeviceRefreshTimer?.cancel();
    _trustSweepTimer?.cancel();
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
    _trustSweepTimer?.cancel();
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
      // Covers coming back from the system "All files access" screen.
      _syncAndroidDownloadDir();
      _discovery?.refreshSelf();
      _pollClipboard();
      _resolveManualDevices();
    }
  }

  /// Asks every peer to re-announce right now instead of waiting for the
  /// next periodic tick, and rechecks manually-added devices too — backs
  /// the pull-to-refresh / refresh button on the Nearby and Browse
  /// screens. Waits briefly for responses to land so the caller's
  /// loading indicator reflects real work instead of resolving before
  /// anything could possibly have changed.
  Future<void> refreshDevices() async {
    _discovery?.refreshSelf();
    await Future.wait([
      _resolveManualDevices(),
      Future.delayed(const Duration(milliseconds: 700)),
    ]);
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
      final device = (await _client.probeDevice(address: address)).device;
      _manualDevices[device.id] = device;
      await manualDevices.remember(device);
    } catch (e) {
      manualAddError = 'Could not reach $address: $e';
    }
    notifyListeners();
  }

  /// The QR-scan equivalent of "Add device by IP" then tapping Pair,
  /// collapsed into one step since scanning is already the deliberate
  /// pairing action. Probes [address]:[port], adds whatever answers as a
  /// device, then immediately starts pairing with it. Rethrows on a probe
  /// failure (unreachable address, garbage QR content) so the scan screen
  /// can show it inline the same way [manualAddError] does for manual add.
  Future<String> pairByAddress(String address, int port) async {
    final device = (await _client.probeDevice(address: address, port: port)).device;
    _manualDevices[device.id] = device;
    await manualDevices.remember(device);
    notifyListeners();
    return initiatePairing(device);
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
  ///
  /// If a sweep is already running (periodic timer, app-resume, or a
  /// concurrent call), returns the SAME in-flight future rather than an
  /// instant no-op — a caller that explicitly awaits this (like
  /// [refreshDevices]) needs to actually wait for the real work, not just
  /// for whichever call happened to arrive first.
  Future<void> _resolveManualDevices() {
    return _manualDevicesSweep ??= _doResolveManualDevices().whenComplete(() {
      _manualDevicesSweep = null;
    });
  }

  Future<void> _doResolveManualDevices() async {
    final stale = _manualDevices.values
        .where((d) => !_discoveredDevices.any((discovered) => discovered.id == d.id))
        .toList();
    if (stale.isEmpty) return;
    for (final device in stale) {
      await _resolveManualDevice(device);
    }
  }

  Future<void> _resolveManualDevice(Device knownDevice) async {
    try {
      final probed = (await _client.probeDevice(
        address: knownDevice.address,
        port: knownDevice.port,
        timeout: _manualDeviceQuickCheckTimeout,
        quiet: true,
      ))
          .device;
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
          return (await _client.probeDevice(address: ip, timeout: _subnetSweepTimeout, quiet: true)).device;
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

  /// Whether Android's "All files access" is currently granted (always
  /// false elsewhere). Drives the Settings row offering to use Downloads.
  bool androidAllFilesGranted = false;

  /// Keeps the Android download folder consistent with "All files access":
  /// granted → move off the app-private default to the real Downloads
  /// folder; revoked → move back off it, since it would no longer be
  /// writable. A folder the user chose themselves is left alone.
  /// [promptOnce] additionally asks for the permission, a single time ever,
  /// so the phone's Downloads folder is the default without anyone having
  /// to find the setting.
  Future<void> _syncAndroidDownloadDir({bool promptOnce = false}) async {
    if (!Platform.isAndroid || !_ready) return;
    try {
      if (promptOnce && !settings.askedAllFilesAccess && !await androidHasAllFilesAccess()) {
        await settings.setAskedAllFilesAccess();
        await androidRequestAllFilesAccess();
      }
      final granted = await androidHasAllFilesAccess();
      final current = settings.downloadDir;
      if (granted && isAppPrivateAndroidPath(current) && await Directory(androidPublicDownloadsDir).exists()) {
        netLog('app', 'all-files access granted — download folder is now $androidPublicDownloadsDir');
        await settings.setDownloadDir(androidPublicDownloadsDir);
      } else if (!granted && current == androidPublicDownloadsDir) {
        final private = await androidPrivateDownloadDir();
        if (private != null) await settings.setDownloadDir(private);
      }
      androidAllFilesGranted = granted;
      notifyListeners();
    } catch (e) {
      netLog('app', 'could not sync the Android download folder: $e');
    }
  }

  /// Explicit "use the phone's Downloads folder" action from Settings.
  Future<bool> useDeviceDownloads() async {
    final granted = await androidRequestAllFilesAccess();
    await _syncAndroidDownloadDir();
    return granted;
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

  Future<void> setTrusted(String deviceId, String name, bool trusted, {bool notifyPeer = true}) async {
    if (trusted) {
      await pairing.trust(deviceId, name);
    } else {
      final fingerprint = pairing.expectedFingerprint(deviceId);
      final wasTrusted = pairing.isTrusted(deviceId);
      await pairing.untrust(deviceId);
      if (notifyPeer && wasTrusted) _sendUnpairHint(deviceId, fingerprint);
      // Clipboard sync is only meaningful between trusted devices —
      // leaving it pointed at a device the user just explicitly untrusted
      // would keep silently pushing clipboard contents to it every poll.
      if (settings.clipboardSyncDeviceId == deviceId) {
        await settings.setClipboardSyncEnabled(false);
        _restartClipboardSync();
      }
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
      final result = await _client.sendPairRequest(
        target: target,
        selfId: settings.deviceId,
        selfName: settings.deviceName,
        code: attempt.code,
        pairId: attempt.id,
      );
      if (result.accepted) {
        await pairing.trust(target.id, target.name);
        // Pin the certificate this exchange actually verified — the human
        // code-compare is what establishes trust; this just gives it
        // cryptographic teeth for every connection from here on.
        await pairing.pinFingerprint(target.id, result.certFingerprint);
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
    if (request.decision.isCompleted) {
      // Already resolved — either the server's decisionTimeout already
      // gave up and declined on our behalf, or this is a duplicate
      // response (e.g. a double-tap before the dialog closed).
      netLog('app', 'ignoring pair response: already resolved');
      notifyListeners();
      return;
    }
    if (accept) {
      await pairing.trust(request.requesterId, request.requesterName);
    }
    request.decision.complete(accept);
    notifyListeners();
  }

  /// Pins [fingerprint] for [deviceId] if it's trusted but has no pinned
  /// fingerprint yet — the case for a device that trusted *us* via an
  /// incoming pair request rather than initiating pairing itself, which
  /// never otherwise gets a chance to observe our certificate until it
  /// makes its own first outgoing connection.
  Future<void> _pinIfUnpinned(String deviceId, String fingerprint) async {
    if (fingerprint.isEmpty) return;
    if (pairing.isTrusted(deviceId) && pairing.expectedFingerprint(deviceId) == null) {
      await pairing.pinFingerprint(deviceId, fingerprint);
    }
  }

  // ---------------------------------------------------------------------
  // Trust reconciliation
  // ---------------------------------------------------------------------
  //
  // Pairing is meant to be mutual, but each device stores its half
  // separately, so the halves can drift apart: one side removes the other
  // while it's offline, a pairing's accept never reaches its requester, and
  // so on. Rather than trying to make every such path atomic, trust is only
  // *kept* while the peer confirms it trusts us back — a device that finds
  // its peer no longer does drops its own half, and both sides converge on
  // "unpaired" (the same state a fresh pairing starts from) instead of one
  // showing Paired while the other offers to Pair.

  /// How long after (re-)trusting a device before its answer to "do you
  /// trust me?" counts. The two halves of a pairing commit moments apart,
  /// so inside this window a "no" is just the other half not landing yet.
  static const _trustGrace = Duration(minutes: 2);
  static const _reconcileMinGap = Duration(seconds: 30);
  static const _trustSweepInterval = Duration(seconds: 60);

  Timer? _trustSweepTimer;
  final Map<String, DateTime> _lastReconcile = {};
  final Set<String> _reconciling = {};

  /// Asks [device], if we trust it, whether it still trusts us, and drops
  /// our trust if it says it doesn't. "No information" (unreachable, wrong
  /// certificate, an older app without the endpoint) never drops anything.
  Future<void> reconcileTrust(Device device, {bool force = false}) async {
    final id = device.id;
    if (!pairing.isTrusted(id) || !_reconciling.add(id)) return;
    try {
      final last = _lastReconcile[id];
      if (!force && last != null && DateTime.now().difference(last) < _reconcileMinGap) return;
      _lastReconcile[id] = DateTime.now();

      final pairedAt = pairing.pairedAt(id);
      if (pairedAt != null) {
        final remaining = _trustGrace - DateTime.now().difference(pairedAt);
        if (remaining > Duration.zero) {
          // Too soon to judge — look again once the grace period is over,
          // so a pairing undone inside it still gets cleaned up.
          Timer(remaining + const Duration(seconds: 2), () {
            final current = devices.where((d) => d.id == id);
            if (current.isNotEmpty) reconcileTrust(current.first, force: true);
          });
          return;
        }
      }

      var fingerprint = pairing.expectedFingerprint(id);
      if (fingerprint == null) {
        // Trusted but never pinned (we were the side that accepted a pair
        // request, and haven't connected out since). Pin now — the same
        // trust-on-first-use step the first outgoing connection would
        // take — after confirming this address really is that device.
        try {
          final probe = await _client.probeDevice(address: device.address, port: device.port, quiet: true);
          if (probe.device.id != id || probe.certFingerprint.isEmpty) return;
          await _pinIfUnpinned(id, probe.certFingerprint);
          fingerprint = pairing.expectedFingerprint(id);
        } catch (_) {
          return;
        }
        if (fingerprint == null) return;
      }

      final theyTrustUs = await _client.checkTrust(
        target: device,
        selfId: settings.deviceId,
        expectedFingerprint: fingerprint,
      );
      // Re-pairing while the check was in flight restarts the grace
      // period; that answer predates it and must not undo the new pairing.
      if (theyTrustUs == false && pairing.isTrusted(id) && pairing.pairedAt(id) == pairedAt) {
        netLog('app', '${device.name} no longer trusts us — dropping our side of the pairing');
        await setTrusted(id, device.name, false, notifyPeer: false);
      }
    } finally {
      _reconciling.remove(id);
    }
  }

  /// A peer says it unpaired us: confirm with the peer itself (the hint
  /// alone proves nothing) as soon as it's reachable, instead of waiting
  /// for the next sweep.
  void _onUnpairHint(String peerId) {
    final match = devices.where((d) => d.id == peerId);
    if (match.isNotEmpty) reconcileTrust(match.first, force: true);
  }

  void _sendUnpairHint(String deviceId, String? fingerprint) {
    final match = devices.where((d) => d.id == deviceId);
    if (match.isEmpty) return; // Offline: the peer's own sweep will find out.
    _client.sendUnpairHint(target: match.first, selfId: settings.deviceId, expectedFingerprint: fingerprint);
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
        expectedFingerprint: pairing.expectedFingerprint(target.id),
      );
      // Closes a gap one-way pairing would otherwise leave open: only the
      // side that *initiated* pairing pins a fingerprint there, so the
      // other side stayed permanently unpinned until its own first
      // outgoing connection. Pin it here, opportunistically, the first
      // time that happens.
      await _pinIfUnpinned(target.id, result.certFingerprint);

      if (canceled) throw const TransferCanceledException();

      if (!result.accepted) {
        netLog('app', '${record.id} declined by ${target.name}');
        record.status = TransferStatus.declined;
        await _finishRecord(record);
        return;
      }

      // The receiver chose to trust us from its accept dialog; if we showed
      // a pairing code for this send, trust it back so that choice doesn't
      // leave the pairing existing on one side only.
      if (result.peerTrustsUs && record.pairingCode != null && !pairing.isTrusted(target.id)) {
        await pairing.trust(target.id, target.name);
        await pairing.pinFingerprint(target.id, result.certFingerprint);
        netLog('app', '${target.name} trusted us from the accept dialog — trusting it back');
      }

      record.status = TransferStatus.transferring;
      notifyListeners();

      var bytesBeforeCurrentFile = 0;
      for (var i = 0; i < files.length; i++) {
        if (canceled) throw const TransferCanceledException();
        final fileIndex = i;
        final baseBytes = bytesBeforeCurrentFile;
        await _withRetry(
          record: record,
          isCanceled: () => canceled,
          confirmedBytes: () async {
            try {
              return await _client.uploadStatus(
                target: target,
                transferId: record.id,
                fileIndex: fileIndex,
                expectedFingerprint: pairing.expectedFingerprint(target.id),
              );
            } catch (_) {
              return 0;
            }
          },
          attempt: (resumeFrom) {
            final speed = SpeedTracker(baseBytes + resumeFrom);
            return _client.uploadFile(
              target: target,
              transferId: record.id,
              fileIndex: fileIndex,
              file: files[fileIndex],
              resumeFrom: resumeFrom,
              isCanceled: () => canceled,
              expectedFingerprint: pairing.expectedFingerprint(target.id),
              onProgress: (sent, total) {
                record.bytesTransferred = baseBytes + sent;
                if (speed.sample(record.bytesTransferred, record.totalBytes, record)) notifyListeners();
              },
            );
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
      if (request.decision.isCompleted) {
        netLog('app', 'ignoring decline for ${request.transferId}: already resolved');
        return;
      }
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
    if (request.decision.isCompleted) {
      // Already resolved — either the sender's connection already timed
      // out server-side (TransferServer.decisionTimeout) or this is a
      // duplicate accept (e.g. a double-tap before the dialog closed). The
      // sender has already been told "decline" and stopped listening in
      // the timeout case, so creating a record here would just produce a
      // "transferring" transfer that never receives a single byte.
      netLog('app', 'ignoring accept for ${request.transferId}: already resolved');
      return;
    }
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
    Stream<List<int>> data, {
    int resumeFrom = 0,
  }) async {
    final key = '${request.transferId}#$fileIndex';
    // A resumed upload arriving is itself the signal that the sender is
    // still trying — cancel any pending "give up" timer from a prior
    // attempt's stall.
    _incomingStallTimers.remove(key)?.cancel();

    final record = activeTransfers[request.transferId];
    final bytesBeforeCurrentFile = request.files.sublist(0, fileIndex).fold<int>(0, (s, f) => s + f.size);

    // Registered before any awaited I/O so a cancel arriving before the
    // stream subscription even exists (e.g. during uniqueSavePath's disk
    // access below) is captured here instead of silently ignored —
    // otherwise cancelTransfer finds no handler registered yet, takes its
    // "already finalized elsewhere" fallback branch, and this download
    // proceeds to completion anyway after already having been marked
    // canceled and moved into history.
    var earlyCancel = false;
    _cancelHandlers[request.transferId] = () => earlyCancel = true;

    // A resume reuses the exact path a prior attempt already picked for
    // this file rather than calling uniqueSavePath again, which would
    // otherwise mint a second "name (1).ext" next to the original partial.
    final knownPath = _incomingFilePaths[key];
    final resuming = resumeFrom > 0 && knownPath != null;
    final String savePath;
    try {
      savePath = resuming ? knownPath : await uniqueSavePath(settings.downloadDir, meta.name);
    } catch (e) {
      _cancelHandlers.remove(request.transferId);
      rethrow;
    }
    _incomingFilePaths[key] = savePath;

    if (earlyCancel) {
      _cancelHandlers.remove(request.transferId);
      _incomingFilePaths.remove(key);
      // cancelTransfer found this early handler and just flipped the
      // bool above rather than finalizing anything itself (that's the
      // whole point — a handler existing means it defers to us) — so we
      // own finalizing the record as canceled here before unwinding.
      if (record != null) {
        record.status = TransferStatus.canceled;
        await _finishRecord(record);
      }
      throw const TransferCanceledException();
    }

    final effectiveResumeFrom = resuming ? resumeFrom : 0;
    netLog('app', 'saving incoming ${request.transferId} file $fileIndex (${meta.name}, ${meta.size}b) -> $savePath'
        '${effectiveResumeFrom > 0 ? ' (resuming from $effectiveResumeFrom)' : ''}');
    final sink = File(savePath).openWrite(mode: effectiveResumeFrom > 0 ? FileMode.append : FileMode.write);
    if (record != null) {
      record.status = TransferStatus.transferring;
      record.error = null;
    }

    var received = effectiveResumeFrom;
    final speed = SpeedTracker(bytesBeforeCurrentFile + effectiveResumeFrom);
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = data.timeout(_stallTimeout).listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (record != null) {
          record.bytesTransferred = bytesBeforeCurrentFile + received;
          if (speed.sample(record.bytesTransferred, record.totalBytes, record)) notifyListeners();
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
      netLog('app', 'incoming ${request.transferId} file $fileIndex saved, $received bytes total');
      record?.savedPaths.add(savePath);
      _incomingFilePaths.remove(key);
      _publishToDownloads(savePath, meta.name);

      if (record != null && fileIndex == request.files.length - 1) {
        record.status = TransferStatus.completed;
        await _finishRecord(record);
      }
    } catch (e) {
      netLog('app', 'incoming ${request.transferId} file $fileIndex errored after $received/$bytesBeforeCurrentFile+'
          '${meta.size} bytes: $e');
      await sink.close();
      final canceled = e is TransferCanceledException;
      if (canceled) {
        _incomingFilePaths.remove(key);
        if (record != null) {
          record.status = TransferStatus.canceled;
          await _finishRecord(record);
        }
      } else if (record != null) {
        // Not finalized: the partial file and the record both stay put so
        // a resumed upload (the sender's own retry, driven by its
        // Content-Range) can pick up right where this left off. Give up
        // for good only if no resume arrives within _incomingResumeTimeout
        // — there's no receiver-side retry action to wait on indefinitely.
        record.status = TransferStatus.stalled;
        record.error = e is TimeoutException ? 'Connection stalled — no data received' : e.toString();
        record.speedBytesPerSec = null;
        record.eta = null;
        notifyListeners();
        _incomingStallTimers[key] = Timer(_incomingResumeTimeout, () {
          _incomingStallTimers.remove(key);
          _incomingFilePaths.remove(key);
          final r = activeTransfers[request.transferId];
          if (r != null && r.status == TransferStatus.stalled) {
            r.status = TransferStatus.failed;
            r.error = 'The sender never resumed';
            _finishRecord(r);
          }
        });
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

  /// Whether [transferId] is [TransferStatus.stalled] and waiting on a
  /// manual [retryTransfer] call rather than mid-backoff on an automatic
  /// one — what a Retry button in the UI should key off of.
  bool canRetry(String transferId) => _manualRetryTriggers.containsKey(transferId);

  /// Manually retries a transfer that's given up on its automatic retries.
  /// A no-op if [transferId] isn't actually waiting for exactly this (e.g.
  /// it's an incoming push, which has no retry of its own, or it already
  /// finished).
  void retryTransfer(String transferId) {
    _manualRetryTriggers.remove(transferId)?.complete();
  }

  /// Runs [attempt] with the number of bytes the other end already has (as
  /// reported by [confirmedBytes], so a resume picks up in the right place
  /// rather than guessing from local state), retrying transient failures a
  /// few times with backoff. If those are all exhausted too, surfaces
  /// [TransferStatus.stalled] and waits indefinitely for a [retryTransfer]
  /// call (or a cancellation) rather than failing the transfer outright —
  /// used by both outgoing sends and browse downloads, the two cases where
  /// this device is the one actively driving the network calls and so the
  /// only ones a manual retry actually means something for.
  Future<void> _withRetry({
    required TransferRecord record,
    required bool Function() isCanceled,
    required Future<int> Function() confirmedBytes,
    required Future<void> Function(int resumeFrom) attempt,
  }) async {
    while (true) {
      for (var i = 0; i <= _retryBackoffs.length; i++) {
        if (isCanceled()) throw const TransferCanceledException();
        try {
          final resumeFrom = await confirmedBytes();
          record.status = TransferStatus.transferring;
          record.error = null;
          notifyListeners();
          await attempt(resumeFrom);
          return;
        } on TransferCanceledException {
          rethrow;
        } catch (e) {
          if (isCanceled()) throw const TransferCanceledException();
          record.status = TransferStatus.stalled;
          record.error = 'Connection lost';
          record.speedBytesPerSec = null;
          record.eta = null;
          notifyListeners();
          if (i == _retryBackoffs.length) break;
          netLog('app', '${record.id} attempt failed ($e); retrying in ${_retryBackoffs[i].inSeconds}s');
          await Future.delayed(_retryBackoffs[i]);
        }
      }
      await _waitForManualRetry(record);
    }
  }

  Future<void> _waitForManualRetry(TransferRecord record) async {
    final waiter = Completer<void>();
    _manualRetryTriggers[record.id] = waiter;
    final priorCancel = _cancelHandlers[record.id];
    _cancelHandlers[record.id] = () {
      priorCancel?.call();
      _manualRetryTriggers.remove(record.id)?.completeError(const TransferCanceledException());
    };
    notifyListeners(); // canRetry(record.id) just flipped to true
    try {
      await waiter.future;
    } finally {
      _manualRetryTriggers.remove(record.id);
      if (priorCancel != null) _cancelHandlers[record.id] = priorCancel;
    }
  }

  /// How many bytes of an incoming file this device already has on disk —
  /// answers a sender's pre-resume check. 0 for a file that was never
  /// started (never stalled, or already completed and forgotten).
  Future<int> _uploadStatusFor(String transferId, int fileIndex) async {
    final path = _incomingFilePaths['$transferId#$fileIndex'];
    if (path == null) return 0;
    final file = File(path);
    return await file.exists() ? await file.length() : 0;
  }

  Future<void> _finishRecord(TransferRecord record) async {
    // Guards against the same record being finalized twice — e.g.
    // cancelTransfer's fallback path racing with the transfer's own
    // completion/failure path — which would otherwise insert it into
    // completedTransfers and persisted history more than once. Set.add
    // returns false if the id was already present.
    if (!_finalizedTransferIds.add(record.id)) return;
    record.finishedAt ??= DateTime.now();
    record.speedBytesPerSec = null;
    record.eta = null;
    activeTransfers.remove(record.id);
    completedTransfers.insert(0, record);
    await history.append(record);
    notifyListeners();

    // Only the "you got something" case — an incoming push or a browse
    // download, both recorded with direction == incoming — not outgoing
    // sends, to avoid spamming a notification per file on a multi-file send.
    if (record.status == TransferStatus.completed && record.direction == TransferDirection.incoming) {
      _notifications?.showTransferComplete(record);
    }
  }

  /// Android only: copies a just-completed incoming file into the public
  /// MediaStore Downloads collection, so it shows up in the Files app and
  /// other apps' pickers without needing a storage permission grant. Fire
  /// and forget — [savePath] in the app's own folder is already the saved
  /// file; this is a visibility nice-to-have, never something a transfer's
  /// success should depend on.
  void _publishToDownloads(String savePath, String fileName) {
    // Only needed for the app-private folder; a file already saved into the
    // public Downloads folder would just be duplicated by a copy.
    if (!Platform.isAndroid || !isAppPrivateAndroidPath(savePath)) return;
    androidPublishToDownloads(savePath, fileName).then((ok) {
      if (!ok) netLog('app', 'could not publish $fileName to Downloads (non-fatal)');
    });
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
    return _client.browse(
      target: device,
      requesterId: settings.deviceId,
      path: path,
      expectedFingerprint: pairing.expectedFingerprint(device.id),
    );
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

  /// Downloads several [entries] from [device]'s shared folder, up to
  /// [concurrency] at a time rather than all at once — avoids saturating
  /// the peer's server or a throttled mobile network stack. Each entry
  /// still becomes its own independent [TransferRecord]/Activity row,
  /// exactly as if downloaded one at a time via [startDownload]; there's no
  /// separate "batch" record type.
  Future<void> batchDownload(Device device, List<RemoteEntry> entries, String parentPath, {int concurrency = 2}) async {
    if (entries.isEmpty) return;
    final queue = List<RemoteEntry>.from(entries);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final entry = queue.removeAt(0);
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
        await _runBrowseDownload(device, entry, parentPath, record);
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, entries.length), (_) => worker()));
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
      await _withRetry(
        record: record,
        isCanceled: () => canceled,
        confirmedBytes: () async {
          final partial = File(savePath);
          return await partial.exists() ? await partial.length() : 0;
        },
        attempt: (resumeFrom) {
          final speed = SpeedTracker(resumeFrom);
          return _client.fetchFile(
            target: device,
            requesterId: settings.deviceId,
            remotePath: remotePath,
            savePath: savePath,
            resumeFrom: resumeFrom,
            isCanceled: () => canceled,
            expectedFingerprint: pairing.expectedFingerprint(device.id),
            onProgress: (received, total) {
              record.bytesTransferred = received;
              if (speed.sample(received, record.totalBytes, record)) notifyListeners();
            },
          );
        },
      );
      record.status = TransferStatus.completed;
      record.savedPaths.add(savePath);
      _publishToDownloads(savePath, entry.name);
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
    // Synchronous + off the main isolate, not the more natural dir.list()
    // stream: on macOS, when downloadDir is the default ~/Downloads — reached
    // from inside the App Sandbox container through its
    // Data/Downloads -> ~/Downloads symlink — Dart's async directory-listing
    // implementation (which hands the request to an internal worker thread
    // and waits on a callback) hangs indefinitely, apparently an interaction
    // between that worker-thread dispatch and the sandbox's mediation of the
    // symlinked path. The synchronous syscalls this uses instead don't hit
    // that path, and running them via Isolate.run keeps a renewed hang (on a
    // future macOS version, another symlinked folder, etc.) from freezing
    // the whole app rather than just the one request.
    final entries = await Isolate.run(() => _listDirSync(dirPath));
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
    if (!pairing.isTrusted(targetId)) {
      // Defense in depth: sync should never run against an untrusted
      // device even if clipboardSyncDeviceId is somehow still pointed at
      // one — setTrusted already clears this on untrust, but this is the
      // one place that actually pushes clipboard contents over the
      // network, so it shouldn't have to rely solely on that.
      await settings.setClipboardSyncEnabled(false);
      _restartClipboardSync();
      return;
    }
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
      await _client.sendClipboard(
        target: target,
        requesterId: settings.deviceId,
        text: text,
        expectedFingerprint: pairing.expectedFingerprint(target.id),
      );
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

/// The synchronous half of [AppState._listRemoteDir], run on a background
/// isolate via [Isolate.run] — see the comment there for why this needs to
/// be synchronous. Top-level (not a method) because [Isolate.run]'s closure
/// must not capture an [AppState] instance.
List<RemoteEntry> _listDirSync(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return [];
  final entries = <RemoteEntry>[];
  for (final entity in dir.listSync(followLinks: false)) {
    final stat = entity.statSync();
    entries.add(RemoteEntry(
      name: p.basename(entity.path),
      isDir: entity is Directory,
      size: entity is File ? stat.size : 0,
      modified: stat.modified,
    ));
  }
  return entries;
}
