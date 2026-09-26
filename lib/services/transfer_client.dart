import 'dart:convert';
import 'dart:io';

import '../models/device.dart';
import '../models/remote_entry.dart';
import '../models/transfer.dart';
import '../util/net_log.dart';
import 'transfer_server.dart' show TransferServer;

class TransferOfferResult {
  final bool accepted;
  const TransferOfferResult({required this.accepted});
}

/// Thrown to unwind an in-progress upload when the user cancels it locally.
class TransferCanceledException implements Exception {
  const TransferCanceledException();
  @override
  String toString() => 'Canceled by user';
}

/// Sends offers and file bytes to a remote peer's [TransferServer].
class TransferClient {
  static const Duration offerTimeout = Duration(seconds: 65);

  Future<TransferOfferResult> sendOffer({
    required Device target,
    required String selfId,
    required String selfName,
    required String transferId,
    required List<FileMeta> files,
    required String pairingCode,
  }) async {
    final client = HttpClient();
    final uri = Uri.parse('http://${target.address}:${target.port}/offer');
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
      return TransferOfferResult(accepted: json['decision'] == 'accept');
    } catch (e) {
      netLog('client', 'offer $transferId to $uri failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> sendPairRequest({
    required Device target,
    required String selfId,
    required String selfName,
    required String code,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://${target.address}:${target.port}/pair');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'id': selfId, 'name': selfName, 'code': code}));
      final response = await request.close().timeout(offerTimeout);
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['decision'] == 'accept';
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
    bool Function()? isCanceled,
  }) async {
    final client = HttpClient();
    final length = await file.length();
    final uri = Uri.parse('http://${target.address}:${target.port}/upload/$transferId/$fileIndex');
    netLog('client', 'uploading $transferId file $fileIndex to $uri ($length bytes)');
    final sw = Stopwatch()..start();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.binary;
      request.contentLength = length;

      int sent = 0;
      onProgress(0, length);
      await for (final chunk in file.openRead()) {
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
      netLog('client', 'upload $transferId file $fileIndex done, response ${response.statusCode}, '
          'total ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      netLog('client', 'upload $transferId file $fileIndex failed after ${sw.elapsedMilliseconds}ms: $e');
      rethrow;
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
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://${target.address}:${target.port}/browse')
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
    bool Function()? isCanceled,
  }) async {
    final client = HttpClient();
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse('http://${target.address}:${target.port}/fetch')
          .replace(queryParameters: {'requesterId': requesterId, 'path': remotePath});
      netLog('client', 'fetching "$remotePath" from ${target.name} -> $savePath');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode == HttpStatus.forbidden) {
        throw Exception('Not paired with ${target.name}');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Fetch failed (${response.statusCode})');
      }
      final total = response.contentLength;
      final sink = File(savePath).openWrite();
      var received = 0;
      onProgress(0, total);
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
      netLog('client', 'fetch "$remotePath" done, $received bytes in ${sw.elapsedMilliseconds}ms');
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
  }) async {
    final client = HttpClient();
    final uri = Uri.parse('http://${target.address}:${target.port}/clipboard');
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
  /// between Wi-Fi clients while unicast still works fine).
  Future<Device> probeDevice({required String address, int port = TransferServer.defaultPort}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://$address:$port/whoami');
      netLog('client', 'probing $uri');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Device did not respond (${response.statusCode})');
      }
      final body = await utf8.decoder.bind(response).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return Device(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String,
        address: address,
        port: port,
        lastSeen: DateTime.now(),
      );
    } catch (e) {
      netLog('client', 'probe $address:$port failed: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
