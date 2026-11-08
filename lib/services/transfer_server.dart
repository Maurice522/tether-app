import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/pairing_request.dart';
import '../models/remote_entry.dart';
import '../models/transfer.dart';
import '../util/net_log.dart';

/// Resolves where an incoming file's bytes should be written, and is
/// handed the live byte stream to save. Implemented by the app layer so
/// this service stays free of platform-specific storage logic; the
/// implementer already knows (request, fileIndex) and can report its own
/// progress against the [TransferRecord] it owns.
typedef FileSink = Future<void> Function(
  IncomingTransferRequest request,
  int fileIndex,
  FileMeta meta,
  Stream<List<int>> data, {
  int resumeFrom,
});

/// How many bytes of file [fileIndex] in transfer [transferId] the app
/// layer already has on disk — asked by a sender before resuming an
/// interrupted upload, so it knows where to continue from instead of
/// restarting the whole file.
typedef UploadStatusCheck = Future<int> Function(String transferId, int fileIndex);

/// Whether [requesterId] is a paired device allowed to browse/fetch this
/// device's shared folder. Same trust store as offers/pairing — a peer id
/// is only ever meaningful because the local pairing store says so.
typedef TrustCheck = bool Function(String requesterId);

/// Lists the immediate children of [relativePath] ("" for the shared
/// folder's root, otherwise "/"-separated segments). Implemented by the
/// app layer, which owns the actual root directory and its sandboxing.
typedef DirLister = Future<List<RemoteEntry>> Function(String relativePath);

/// Resolves a "/"-separated relative path to a local [File] for reading.
/// Throws if the path escapes the shared root.
typedef FileOpener = File Function(String relativePath);

/// Called when a paired device pushes its clipboard text to this one.
typedef ClipboardSink = void Function(String text);

/// Called when a peer says it unpaired [peerId]. Purely a hint to go
/// re-verify that peer's side — never itself grounds to drop trust, since
/// the claim comes over an unauthenticated channel.
typedef UnpairHint = void Function(String peerId);

/// Runs the local HTTP endpoint peers POST offers and file bytes to.
///
/// Protocol:
///  - `POST /offer` — JSON metadata for one or more files. The handler
///    calls [onIncomingRequest] and then blocks (holding the sender's
///    HTTP connection open) until [IncomingTransferRequest.decision] is
///    completed by the UI, or a timeout elapses. Responds with
///    `{"decision":"accept"}` or `{"decision":"decline"}`.
///  - `POST /upload/<transferId>/<fileIndex>` — raw file bytes for a file
///    from a previously accepted offer. Streamed straight to [onFileSink]
///    so large files never sit fully in memory. A `Content-Range` request
///    header (legitimate per RFC 7233, if unusual — most requests carrying
///    one are PATCHes) means this body is only the tail of the file
///    starting at the range's first byte, resuming an upload that was
///    previously interrupted partway through.
///  - `GET /upload-status/<transferId>/<fileIndex>` — how many bytes of
///    that file the receiver already has, so a sender can resume an
///    interrupted upload from the right offset instead of restarting it.
///  - `GET /browse?requesterId=<id>&path=<relative>` — lists the shared
///    folder's contents for an already-paired peer. No approval prompt:
///    pairing is the trust boundary, same as sending files.
///  - `GET /fetch?requesterId=<id>&path=<relative>` — streams one file's
///    bytes from the shared folder back to an already-paired peer. Honors
///    a standard `Range: bytes=<start>-` request header with a `206`
///    response, so an interrupted download can resume instead of
///    restarting.
///  - `POST /pair` — a pairing request; holds the connection open for the
///    local decision like `/offer`. The body's `pairId` lets the requester
///    recover the outcome via `GET /pair-status?pairId=<id>` if that
///    connection drops after the user has already decided, instead of
///    being left unpaired on one side only. Outcomes are kept for
///    [pairResultRetention].
///  - `GET /trust-check?id=<id>` — `{"trusted":bool}`: whether this
///    device currently trusts [id]. Lets a peer notice it was unpaired
///    while it was offline and drop its own half of the pairing.
///  - `POST /unpair` — `{"id":<id>}` hint that [id] unpaired this device,
///    prompting an immediate trust re-check rather than waiting for the
///    next periodic one.
class TransferServer {
  static const Duration decisionTimeout = Duration(seconds: 60);

  /// How long a pairing decision stays queryable via `/pair-status` —
  /// comfortably longer than [decisionTimeout] plus a requester's polling.
  static const Duration pairResultRetention = Duration(minutes: 10);

  /// Fixed port the server tries first, so a device can be added manually
  /// by IP alone (no need to also know/type a port) — useful when
  /// broadcast discovery isn't reaching a peer (e.g. a router that filters
  /// broadcast/multicast between Wi-Fi clients while still routing normal
  /// unicast traffic fine). Falls back to an OS-assigned port if this one
  /// is already taken, so startup never fails outright over a conflict.
  static const int defaultPort = 57892;

  final void Function(IncomingTransferRequest request) onIncomingRequest;
  final void Function(IncomingPairRequest request) onIncomingPairRequest;
  final FileSink onFileSink;
  final UploadStatusCheck onUploadStatus;
  final TrustCheck isTrusted;
  final DirLister onListDir;
  final FileOpener onOpenFile;
  final ClipboardSink onClipboard;
  final UnpairHint onUnpairHint;
  final String selfId;
  final String Function() selfName;
  final String selfPlatform;
  final SecurityContext securityContext;

  HttpServer? _server;
  final Map<String, IncomingTransferRequest> _pending = {};
  final Map<String, IncomingTransferRequest> _accepted = {};
  // pairId -> outcome ('pending' | 'accepted' | 'declined'), see /pair-status.
  final Map<String, ({String status, DateTime at})> _pairResults = {};

  TransferServer({
    required this.onIncomingRequest,
    required this.onIncomingPairRequest,
    required this.onFileSink,
    required this.onUploadStatus,
    required this.isTrusted,
    required this.onListDir,
    required this.onOpenFile,
    required this.onClipboard,
    required this.onUnpairHint,
    required this.selfId,
    required this.selfName,
    required this.selfPlatform,
    required this.securityContext,
  });

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    try {
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, defaultPort, securityContext);
    } catch (e) {
      netLog('server', 'bind to default port $defaultPort failed ($e), falling back to an OS-assigned port');
      _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, securityContext);
    }
    netLog('server', 'listening on port ${_server!.port}');
    _server!.listen(_handle, onError: (e) => netLog('server', 'listen error: $e'));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    netLog('server', '${request.method} ${request.uri.path} from ${request.connectionInfo?.remoteAddress.address}');
    try {
      if (request.method == 'POST' && request.uri.path == '/offer') {
        await _handleOffer(request);
      } else if (request.method == 'POST' && request.uri.path == '/pair') {
        await _handlePair(request);
      } else if (request.method == 'POST' && request.uri.pathSegments.length == 3 && request.uri.pathSegments[0] == 'upload') {
        await _handleUpload(request);
      } else if (request.method == 'GET' && request.uri.pathSegments.length == 3 && request.uri.pathSegments[0] == 'upload-status') {
        await _handleUploadStatus(request);
      } else if (request.method == 'GET' && request.uri.path == '/browse') {
        await _handleBrowse(request);
      } else if (request.method == 'GET' && request.uri.path == '/fetch') {
        await _handleFetch(request);
      } else if (request.method == 'POST' && request.uri.path == '/clipboard') {
        await _handleClipboard(request);
      } else if (request.method == 'GET' && request.uri.path == '/pair-status') {
        await _handlePairStatus(request);
      } else if (request.method == 'GET' && request.uri.path == '/trust-check') {
        await _handleTrustCheck(request);
      } else if (request.method == 'POST' && request.uri.path == '/unpair') {
        await _handleUnpair(request);
      } else if (request.method == 'GET' && request.uri.path == '/whoami') {
        await _handleWhoami(request);
      } else {
        netLog('server', 'unmatched request: ${request.method} ${request.uri.path}');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e, st) {
      netLog('server', 'handler error for ${request.uri.path}: $e\n$st');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // Response may already be closed/broken; nothing more to do.
      }
    }
  }

  Future<void> _handleOffer(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final transferId = json['transferId'] as String;
    final files = (json['files'] as List)
        .map((f) => FileMeta.fromJson(f as Map<String, dynamic>))
        .toList();

    final incoming = IncomingTransferRequest(
      transferId: transferId,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      senderAddress: request.connectionInfo?.remoteAddress.address ?? 'unknown',
      files: files,
      pairingCode: json['pairingCode'] as String? ?? '',
    );
    _pending[transferId] = incoming;
    netLog('server', 'offer $transferId from ${incoming.senderName} (${incoming.files.length} file(s), '
        '${incoming.totalBytes} bytes) — waiting for local decision');
    onIncomingRequest(incoming);

    bool accepted;
    try {
      accepted = await incoming.decision.future.timeout(decisionTimeout);
    } catch (e) {
      netLog('server', 'offer $transferId decision timed out/errored: $e');
      accepted = false;
      // The wait gave up, but the Completer itself is still open — if the
      // app layer later completes it for real (a very late accept/decline
      // tap), that call would otherwise succeed with no one listening,
      // creating a transfer that thinks it's proceeding when this
      // connection has already been closed. Closing it here lets the app
      // layer detect and ignore a late response instead.
      if (!incoming.decision.isCompleted) incoming.decision.complete(false);
    }
    _pending.remove(transferId);
    if (accepted) _accepted[transferId] = incoming;
    netLog('server', 'offer $transferId decided: ${accepted ? 'accept' : 'decline'}');

    request.response.headers.contentType = ContentType.json;
    // Whether we now trust the sender — true for an already-paired sender
    // or one the user just chose "trust" for on the accept dialog. Tells
    // a sender that showed a pairing code to trust us back, so that
    // choice doesn't leave a pairing that exists on only one side.
    request.response.write(jsonEncode({
      'decision': accepted ? 'accept' : 'decline',
      'trusted': accepted && isTrusted(incoming.senderId),
    }));
    await request.response.close();
  }

  Future<void> _handlePair(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    final incoming = IncomingPairRequest(
      requesterId: json['id'] as String,
      requesterName: json['name'] as String,
      requesterAddress: request.connectionInfo?.remoteAddress.address ?? 'unknown',
      code: json['code'] as String,
    );
    final pairId = json['pairId'] as String?;
    netLog('server', 'pair request from ${incoming.requesterName} (${incoming.requesterAddress})');
    if (pairId != null) {
      _prunePairResults();
      _pairResults[pairId] = (status: 'pending', at: DateTime.now());
    }
    onIncomingPairRequest(incoming);

    bool accepted;
    try {
      accepted = await incoming.decision.future.timeout(decisionTimeout);
    } catch (e) {
      netLog('server', 'pair request decision timed out/errored: $e');
      accepted = false;
      if (!incoming.decision.isCompleted) incoming.decision.complete(false);
    }
    netLog('server', 'pair request decided: ${accepted ? 'accept' : 'decline'}');
    // Recorded before replying, so a requester whose connection dies right
    // here can still learn the outcome via /pair-status.
    if (pairId != null) {
      _pairResults[pairId] = (status: accepted ? 'accepted' : 'declined', at: DateTime.now());
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'decision': accepted ? 'accept' : 'decline'}));
    await request.response.close();
  }

  void _prunePairResults() {
    final cutoff = DateTime.now().subtract(pairResultRetention);
    _pairResults.removeWhere((_, r) => r.at.isBefore(cutoff));
  }

  Future<void> _handlePairStatus(HttpRequest request) async {
    _prunePairResults();
    final result = _pairResults[request.uri.queryParameters['pairId'] ?? ''];
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': result?.status ?? 'unknown'}));
    await request.response.close();
  }

  Future<void> _handleTrustCheck(HttpRequest request) async {
    final id = request.uri.queryParameters['id'] ?? '';
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'trusted': isTrusted(id)}));
    await request.response.close();
  }

  Future<void> _handleUnpair(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final id = json['id'] as String?;
    if (id != null) onUnpairHint(id);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final transferId = request.uri.pathSegments[1];
    final fileIndex = int.tryParse(request.uri.pathSegments[2]);
    final incoming = _accepted[transferId];
    if (incoming == null || fileIndex == null || fileIndex < 0 || fileIndex >= incoming.files.length) {
      netLog('server', 'upload rejected: transferId=$transferId fileIndex=$fileIndex '
          'knownAccepted=${_accepted.keys.toList()}');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    final meta = incoming.files[fileIndex];
    var resumeFrom = 0;
    final contentRange = request.headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(r'bytes (\d+)-').firstMatch(contentRange);
      if (match != null) resumeFrom = int.parse(match.group(1)!);
    }
    netLog('server', 'upload start $transferId file $fileIndex (${meta.name}, ${meta.size} bytes)'
        ' contentLength=${request.contentLength}${resumeFrom > 0 ? ' resumeFrom=$resumeFrom' : ''}');
    final sw = Stopwatch()..start();
    try {
      await onFileSink(incoming, fileIndex, meta, request, resumeFrom: resumeFrom);
      netLog('server', 'upload done $transferId file $fileIndex in ${sw.elapsedMilliseconds}ms');
      request.response.statusCode = HttpStatus.ok;
      // Only the last file's success ends authorization — earlier files
      // in the same multi-file transfer still have more uploads coming.
      if (fileIndex == incoming.files.length - 1) {
        _accepted.remove(transferId);
      }
    } catch (e) {
      // Unlike a success, a failure here does NOT end authorization — a
      // transient error is exactly what a sender's own retry logic
      // resumes from, and it reuses this same transferId/fileIndex to do
      // so. Authorization only ever ends on the last file's success (or
      // never, if the sender gives up for good) — a leftover entry for an
      // abandoned transfer is harmless, not a growing liability.
      netLog('server', 'upload failed $transferId file $fileIndex after ${sw.elapsedMilliseconds}ms: $e');
      request.response.statusCode = HttpStatus.internalServerError;
    }
    await request.response.close();
  }

  Future<void> _handleUploadStatus(HttpRequest request) async {
    final transferId = request.uri.pathSegments[1];
    final fileIndex = int.tryParse(request.uri.pathSegments[2]);
    if (fileIndex == null || !_accepted.containsKey(transferId)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final bytesReceived = await onUploadStatus(transferId, fileIndex);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'bytesReceived': bytesReceived}));
    await request.response.close();
  }

  Future<void> _handleBrowse(HttpRequest request) async {
    final requesterId = request.uri.queryParameters['requesterId'] ?? '';
    if (!isTrusted(requesterId)) {
      netLog('server', 'browse rejected: requester $requesterId not paired');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final path = request.uri.queryParameters['path'] ?? '';
    try {
      final entries = await onListDir(path);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      netLog('server', 'browse "$path" failed: $e');
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  }

  Future<void> _handleFetch(HttpRequest request) async {
    final requesterId = request.uri.queryParameters['requesterId'] ?? '';
    if (!isTrusted(requesterId)) {
      netLog('server', 'fetch rejected: requester $requesterId not paired');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final path = request.uri.queryParameters['path'] ?? '';
    File file;
    try {
      file = onOpenFile(path);
    } catch (e) {
      netLog('server', 'fetch "$path" rejected: $e');
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final length = await file.length();
    var start = 0;
    final rangeHeader = request.headers.value('range');
    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
      final requested = match == null ? null : int.parse(match.group(1)!);
      if (requested != null && requested > 0 && requested < length) start = requested;
    }
    final partial = start > 0;
    netLog('server', 'fetch "$path" -> ${file.path} ($length bytes${partial ? ", resuming from $start" : ""})');
    request.response.headers.contentType = ContentType.binary;
    request.response.contentLength = length - start;
    if (partial) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set('content-range', 'bytes $start-${length - 1}/$length');
    }
    try {
      await request.response.addStream(partial ? file.openRead(start) : file.openRead());
    } catch (e) {
      netLog('server', 'fetch "$path" stream interrupted: $e');
    }
    await request.response.close();
  }

  Future<void> _handleClipboard(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final requesterId = json['requesterId'] as String? ?? '';
    if (!isTrusted(requesterId)) {
      netLog('server', 'clipboard push rejected: requester $requesterId not paired');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final text = json['text'] as String? ?? '';
    netLog('server', 'clipboard push received from $requesterId (${text.length} chars)');
    onClipboard(text);
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  /// Answers "who are you" with no trust check — this is how a manually
  /// entered IP gets turned into a real [Device] (id/name/platform) when
  /// broadcast discovery isn't reaching a peer. It reveals nothing a
  /// broadcast announce doesn't already reveal to anyone on the LAN.
  Future<void> _handleWhoami(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'id': selfId, 'name': selfName(), 'platform': selfPlatform}));
    await request.response.close();
  }
}
