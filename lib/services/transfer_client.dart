import 'dart:convert';
import 'dart:io';

import '../models/device.dart';
import '../models/transfer.dart';

class TransferOfferResult {
  final bool accepted;
  const TransferOfferResult({required this.accepted});
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
    try {
      final uri = Uri.parse('http://${target.address}:${target.port}/offer');
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
      return TransferOfferResult(accepted: json['decision'] == 'accept');
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
  }) async {
    final client = HttpClient();
    try {
      final length = await file.length();
      final uri = Uri.parse('http://${target.address}:${target.port}/upload/$transferId/$fileIndex');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.binary;
      request.contentLength = length;

      int sent = 0;
      onProgress(0, length);
      await for (final chunk in file.openRead()) {
        request.add(chunk);
        sent += chunk.length;
        onProgress(sent, length);
      }
      final response = await request.close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  }
}
