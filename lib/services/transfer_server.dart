import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/pairing_request.dart';
import '../models/transfer.dart';

/// Resolves where an incoming file's bytes should be written, and is
/// handed the live byte stream to save. Implemented by the app layer so
/// this service stays free of platform-specific storage logic; the
/// implementer already knows (request, fileIndex) and can report its own
/// progress against the [TransferRecord] it owns.
typedef FileSink = Future<void> Function(
  IncomingTransferRequest request,
  int fileIndex,
  FileMeta meta,
  Stream<List<int>> data,
);

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
///    so large files never sit fully in memory.
class TransferServer {
  static const Duration decisionTimeout = Duration(seconds: 60);

  final void Function(IncomingTransferRequest request) onIncomingRequest;
  final void Function(IncomingPairRequest request) onIncomingPairRequest;
  final FileSink onFileSink;

  HttpServer? _server;
  final Map<String, IncomingTransferRequest> _pending = {};
  final Map<String, IncomingTransferRequest> _accepted = {};

  TransferServer({
    required this.onIncomingRequest,
    required this.onIncomingPairRequest,
    required this.onFileSink,
  });

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/offer') {
        await _handleOffer(request);
      } else if (request.method == 'POST' && request.uri.path == '/pair') {
        await _handlePair(request);
      } else if (request.method == 'POST' && request.uri.pathSegments.length == 3 && request.uri.pathSegments[0] == 'upload') {
        await _handleUpload(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (_) {
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
    onIncomingRequest(incoming);

    bool accepted;
    try {
      accepted = await incoming.decision.future.timeout(decisionTimeout);
    } catch (_) {
      accepted = false;
    }
    _pending.remove(transferId);
    if (accepted) _accepted[transferId] = incoming;

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'decision': accepted ? 'accept' : 'decline'}));
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
    onIncomingPairRequest(incoming);

    bool accepted;
    try {
      accepted = await incoming.decision.future.timeout(decisionTimeout);
    } catch (_) {
      accepted = false;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'decision': accepted ? 'accept' : 'decline'}));
    await request.response.close();
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final transferId = request.uri.pathSegments[1];
    final fileIndex = int.tryParse(request.uri.pathSegments[2]);
    final incoming = _accepted[transferId];
    if (incoming == null || fileIndex == null || fileIndex < 0 || fileIndex >= incoming.files.length) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    final meta = incoming.files[fileIndex];
    await onFileSink(incoming, fileIndex, meta, request);

    request.response.statusCode = HttpStatus.ok;
    await request.response.close();

    if (fileIndex == incoming.files.length - 1) {
      _accepted.remove(transferId);
    }
  }
}
