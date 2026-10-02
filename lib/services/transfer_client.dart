import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/device.dart';
import '../models/remote_entry.dart';
import '../models/transfer.dart';
import '../util/net_log.dart';
import 'transfer_server.dart' show TransferServer;

class TransferOfferResult {
  final bool accepted;
  final String certFingerprint;
  const TransferOfferResult({required this.accepted, required this.certFingerprint});
}

/// A [Device] plus the TLS certificate fingerprint it presented during the
/// connection used to resolve it. Used only for the pre-trust cases
/// (probing a manually-entered address, sending a pairing invite) — the
/// caller pins this fingerprint once the user actually decides to trust
/// the device, so later connections can be verified against it.
class ProbeResult {
  final Device device;
  final String certFingerprint;
  const ProbeResult({required this.device, required this.certFingerprint});
}

class PairResult {
  final bool accepted;
  final String certFingerprint;
  const PairResult({required this.accepted, required this.certFingerprint});
}

/// Thrown to unwind an in-progress upload when the user cancels it locally.
class TransferCanceledException implements Exception {
  const TransferCanceledException();
  @override
  String toString() => 'Canceled by user';
}

/// Sends offers and file bytes to a remote peer's [TransferServer].
///
/// Every connection is TLS, using each device's own self-signed
/// certificate — there's no CA, so trust is established the same way it
/// always was (a human comparing a pairing code) with the fingerprint of
/// the certificate seen during that exchange pinned alongside it. Once a
/// device is trusted, every subsequent call passes its pinned
/// [PairingStore.expectedFingerprint] so a wrong certificate is rejected
/// outright rather than silently accepted.
class TransferClient {
  static const Duration offerTimeout = Duration(seconds: 65);

  /// Builds an [HttpClient] whose certificate check pins against
  /// [expectedFingerprint] (rejecting anything else) or accepts whatever
  /// is presented when null — the pre-trust case, safe because probing/
  /// inviting alone never grants access. Always reports the fingerprint it
  /// saw via [onFingerprint], so a caller that's about to grant trust can
  /// pin exactly the certificate this connection actually verified.
  HttpClient _clientFor({
    String? expectedFingerprint,
    void Function(String fingerprint)? onFingerprint,
    Duration? connectionTimeout,
  }) {
    final client = HttpClient();
    if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
    client.badCertificateCallback = (cert, host, port) {
      final fingerprint = sha256.convert(cert.der).toString();
      onFingerprint?.call(fingerprint);
      if (expectedFingerprint == null) return true;
      return fingerprint == expectedFingerprint;
    };
    return client;
  }

  Future<TransferOfferResult> sendOffer({
    required Device target,
    required String selfId,
    required String selfName,
    required String transferId,
    required List<FileMeta> files,
    required String pairingCode,
    String? expectedFingerprint,
  }) async {
    String? seenFingerprint;
    final client = _clientFor(expectedFingerprint: expectedFingerprint, onFingerprint: (fp) => seenFingerprint = fp);
    final uri = Uri.parse('https://${target.address}:${target.port}/offer');
    netLog('client', 'sending offer $transferId to ${target.name} at $uri');
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'transferId': transferId,
        'senderId': selfId,
        'senderName': selfName,
        'files': files.map((f) => f.toJson()).toList(),
        'pairingCode': pairingCode,
      }));
      final response = await request.close().timeout(offerTimeout);
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      netLog('client', 'offer $transferId response: $body');
      return TransferOfferResult(accepted: json['decision'] == 'accept', certFingerprint: seenFingerprint ?? '');
    } catch (e) {
      netLog('client', 'offer $transferId to $uri failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<PairResult> sendPairRequest({
    required Device target,
    required String selfId,
    required String selfName,
    required String code,
  }) async {
    String? seenFingerprint;
    final client = _clientFor(onFingerprint: (fp) => seenFingerprint = fp);
    try {
      final uri = Uri.parse('https://${target.address}:${target.port}/pair');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'id': selfId, 'name': selfName, 'code': code}));
      final response = await request.close().timeout(offerTimeout);
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return PairResult(accepted: json['decision'] == 'accept', certFingerprint: seenFingerprint ?? '');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> uploadFile({
    required Device target,
    required String transferId,
    required int fileIndex,
    required File file,
    required void Function(int sent, int total) onProgress,
    int resumeFrom = 0,
    bool Function()? isCanceled,
    String? expectedFingerprint,
  }) async {
    final client = _clientFor(expectedFingerprint: expectedFingerprint);
    final length = await file.length();
    final uri = Uri.parse('https://${target.address}:${target.port}/upload/$transferId/$fileIndex');
    netLog('client', 'uploading $transferId file $fileIndex to $uri ($length bytes'
        '${resumeFrom > 0 ? ', resuming from $resumeFrom' : ''})');
    final sw = Stopwatch()..start();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.binary;
      request.contentLength = length - resumeFrom;
      if (resumeFrom > 0) {
        request.headers.set('content-range', 'bytes $resumeFrom-${length - 1}/$length');
      }

      int sent = resumeFrom;
      onProgress(sent, length);
      await for (final chunk in file.openRead(resumeFrom)) {
        if (isCanceled?.call() ?? false) {
          throw const TransferCanceledException();
        }
        request.add(chunk);
        sent += chunk.length;
        onProgress(sent, length);
      }
      netLog('client', 'upload $transferId file $fileIndex: all bytes written in '
          '${sw.elapsedMilliseconds}ms, awaiting response...');
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Upload rejected (${response.statusCode})');
      }
      netLog('client', 'upload $transferId file $fileIndex done, response ${response.statusCode}, '
          'total ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      netLog('client', 'upload $transferId file $fileIndex failed after ${sw.elapsedMilliseconds}ms: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Asks [target] how many bytes of file [fileIndex] in [transferId] it
  /// already has, so an interrupted upload can resume from the right
  /// offset. Callers should treat any failure here as "resume from zero"
  /// rather than propagate it — this is an optimization, not something
  /// worth failing the whole retry over.
  Future<int> uploadStatus({
    required Device target,
    required String transferId,
    required int fileIndex,
    String? expectedFingerprint,
  }) async {
    final client = _clientFor(expectedFingerprint: expectedFingerprint);
    try {
      final uri = Uri.parse('https://${target.address}:${target.port}/upload-status/$transferId/$fileIndex');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Upload status check failed (${response.statusCode})');
      }
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['bytesReceived'] as int? ?? 0;
    } finally {
      client.close(force: true);
    }
  }

  /// Lists the immediate children of [path] ("" for the root) in [target]'s
  /// shared folder. Only succeeds if [target] has paired with [requesterId].
  Future<List<RemoteEntry>> browse({
    required Device target,
    required String requesterId,
    required String path,
    String? expectedFingerprint,
  }) async {
    final client = _clientFor(expectedFingerprint: expectedFingerprint);
    try {
      final uri = Uri.parse('https://${target.address}:${target.port}/browse')
          .replace(queryParameters: {'requesterId': requesterId, 'path': path});
      netLog('client', 'browsing "$path" on ${target.name}');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.forbidden) {
        throw Exception('Not paired with ${target.name}');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Browse failed (${response.statusCode})');
      }
      final body = await utf8.decoder.bind(response).join();
      final list = jsonDecode(body) as List;
      return list.map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      netLog('client', 'browse "$path" on ${target.name} failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads one remote file at [remotePath] from [target]'s shared
  /// folder, streaming it straight to [savePath].
  Future<void> fetchFile({
    required Device target,
    required String requesterId,
    required String remotePath,
    required String savePath,
    required void Function(int received, int total) onProgress,
    int resumeFrom = 0,
    bool Function()? isCanceled,
    String? expectedFingerprint,
  }) async {
    final client = _clientFor(expectedFingerprint: expectedFingerprint);
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse('https://${target.address}:${target.port}/fetch')
          .replace(queryParameters: {'requesterId': requesterId, 'path': remotePath});
      netLog('client', 'fetching "$remotePath" from ${target.name} -> $savePath'
          '${resumeFrom > 0 ? ' (resuming from $resumeFrom)' : ''}');
      final request = await client.getUrl(uri);
      if (resumeFrom > 0) request.headers.set('range', 'bytes=$resumeFrom-');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode == HttpStatus.forbidden) {
        throw Exception('Not paired with ${target.name}');
      }
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        throw Exception('Fetch failed (${response.statusCode})');
      }
      // A server that ignored the Range header (or never had the file
      // partial to begin with) sends a plain 200 with the whole file —
      // start over from its actual length rather than trusting resumeFrom.
      final effectiveResumeFrom = response.statusCode == HttpStatus.partialContent ? resumeFrom : 0;
      final total = effectiveResumeFrom + response.contentLength;
      final sink = File(savePath).openWrite(mode: effectiveResumeFrom > 0 ? FileMode.append : FileMode.write);
      var received = effectiveResumeFrom;
      onProgress(received, total);
      try {
        await for (final chunk in response) {
          if (isCanceled?.call() ?? false) {
            throw const TransferCanceledException();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      netLog('client', 'fetch "$remotePath" done, $received bytes total in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      netLog('client', 'fetch "$remotePath" from ${target.name} failed after ${sw.elapsedMilliseconds}ms: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Pushes the local clipboard's text to a paired [target] device.
  Future<void> sendClipboard({
    required Device target,
    required String requesterId,
    required String text,
    String? expectedFingerprint,
  }) async {
    final client = _clientFor(expectedFingerprint: expectedFingerprint);
    final uri = Uri.parse('https://${target.address}:${target.port}/clipboard');
    try {
      netLog('client', 'pushing clipboard (${text.length} chars) to ${target.name} at $uri');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'requesterId': requesterId, 'text': text}));
      final response = await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Clipboard push failed (${response.statusCode})');
      }
    } catch (e) {
      netLog('client', 'clipboard push to $uri failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Resolves [address]:[port] to a real [Device] by asking it directly —
  /// the manual "add device by IP" fallback for when broadcast discovery
  /// isn't reaching a peer (e.g. a router that filters broadcast/multicast
  /// between Wi-Fi clients while unicast still works fine). Always accepts
  /// whatever certificate is presented (there's nothing to pin yet, and
  /// this alone grants no access) — the returned fingerprint lets a caller
  /// that's about to pair with this device pin it afterward.
  Future<ProbeResult> probeDevice({
    required String address,
    int port = TransferServer.defaultPort,
    Duration timeout = const Duration(seconds: 8),
    bool quiet = false,
  }) async {
    String? seenFingerprint;
    final client = _clientFor(onFingerprint: (fp) => seenFingerprint = fp, connectionTimeout: timeout);
    try {
      final uri = Uri.parse('https://$address:$port/whoami');
      if (!quiet) netLog('client', 'probing $uri');
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Device did not respond (${response.statusCode})');
      }
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final device = Device(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String,
        address: address,
        port: port,
        lastSeen: DateTime.now(),
      );
      return ProbeResult(device: device, certFingerprint: seenFingerprint ?? '');
    } catch (e) {
      if (!quiet) netLog('client', 'probe $address:$port failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
