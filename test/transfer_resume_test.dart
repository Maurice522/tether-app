import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tether/models/device.dart';
import 'package:tether/models/transfer.dart';
import 'package:tether/services/transfer_client.dart';
import 'package:tether/services/transfer_server.dart';

/// Exercises the Phase 3 resume protocol (Content-Range on upload, Range on
/// fetch, /upload-status) directly against a real TransferServer/
/// TransferClient pair over loopback TLS — no AppState/path_provider, so it
/// runs headless. AppState's retry orchestration (backoff, stalled status,
/// manual retry) isn't covered here; that needs a live device and is
/// tracked separately.
SecurityContext _generateTestSecurityContext() {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem({'CN': 'test'}, privateKey, publicKey);
  final certPem = X509Utils.generateSelfSignedCertificate(privateKey, csr, 365);
  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
  return SecurityContext()
    ..useCertificateChainBytes(Uint8List.fromList(certPem.codeUnits))
    ..usePrivateKeyBytes(Uint8List.fromList(keyPem.codeUnits));
}

void main() {
  late Directory tempDir;
  late TransferServer server;
  late TransferClient client;
  late Device device;
  late Set<String> interruptedOnce;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tether_resume_test');
    interruptedOnce = {};
    server = TransferServer(
      onIncomingRequest: (req) => req.decision.complete(true),
      onIncomingPairRequest: (req) => req.decision.complete(false),
      // Mirrors AppState._saveIncomingFile closely enough for this test:
      // appends when resuming, and — on a file's very first attempt only —
      // deliberately throws partway through to simulate a dropped
      // connection, leaving exactly what arrived before that point on
      // disk. A real network drop wouldn't stop this cleanly at a byte
      // boundary, but the resume protocol doesn't care where it happened.
      onFileSink: (request, fileIndex, meta, data, {int resumeFrom = 0}) async {
        final key = '${request.transferId}#$fileIndex';
        final path = p.join(tempDir.path, 'received_$fileIndex.bin');
        final sink = File(path).openWrite(mode: resumeFrom > 0 ? FileMode.append : FileMode.write);
        final shouldInterrupt = resumeFrom == 0 && interruptedOnce.add(key);
        var written = resumeFrom;
        try {
          await for (final chunk in data) {
            sink.add(chunk);
            written += chunk.length;
            if (shouldInterrupt && written >= meta.size ~/ 3) {
              throw Exception('simulated connection drop');
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      },
      onUploadStatus: (transferId, fileIndex) async {
        final file = File(p.join(tempDir.path, 'received_$fileIndex.bin'));
        return await file.exists() ? await file.length() : 0;
      },
      isTrusted: (id) => true,
      onListDir: (path) async => [],
      onOpenFile: (relativePath) => File(p.join(tempDir.path, 'shared', relativePath)),
      onClipboard: (_) {},
      selfId: 'receiver-id',
      selfName: () => 'Receiver',
      selfPlatform: 'test',
      securityContext: _generateTestSecurityContext(),
    );
    await server.start();
    client = TransferClient();
    device = Device(id: 'receiver-id', name: 'Receiver', platform: 'test', address: '127.0.0.1', port: server.port, lastSeen: DateTime.now());
  });

  tearDown(() async {
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  test('resumed upload appends to the partial file and produces the original bytes', () async {
    final fullBytes = Uint8List.fromList(List.generate(500 * 1024, (i) => i % 256));
    const transferId = 'xfer-1';

    final offerResult = await client.sendOffer(
      target: device,
      selfId: 'sender-id',
      selfName: 'Sender',
      transferId: transferId,
      files: [FileMeta(name: 'test.bin', size: fullBytes.length)],
      pairingCode: '000000',
    );
    expect(offerResult.accepted, isTrue);

    final fullFile = File(p.join(tempDir.path, 'full.bin'))..writeAsBytesSync(fullBytes);

    // First attempt: the server's FileSink throws partway through (see
    // setUp) to simulate a dropped connection. uploadFile should surface
    // that as a thrown error rather than silently succeeding.
    await expectLater(
      client.uploadFile(target: device, transferId: transferId, fileIndex: 0, file: fullFile, onProgress: (_, _) {}),
      throwsA(anything),
    );

    final status = await client.uploadStatus(target: device, transferId: transferId, fileIndex: 0);
    expect(status, greaterThan(0));
    expect(status, lessThan(fullBytes.length));

    // Second attempt: resume with the same file from the confirmed offset.
    var lastSent = 0;
    await client.uploadFile(
      target: device,
      transferId: transferId,
      fileIndex: 0,
      file: fullFile,
      resumeFrom: status,
      onProgress: (sent, total) {
        lastSent = sent;
        expect(total, fullBytes.length);
      },
    );
    expect(lastSent, fullBytes.length);

    final received = await File(p.join(tempDir.path, 'received_0.bin')).readAsBytes();
    expect(received, equals(fullBytes));
  });

  test('resumed fetch returns 206 for the missing tail and appends correctly', () async {
    final fullBytes = Uint8List.fromList(List.generate(400 * 1024, (i) => (i * 7) % 256));
    final sharedDir = Directory(p.join(tempDir.path, 'shared'))..createSync();
    File(p.join(sharedDir.path, 'download.bin')).writeAsBytesSync(fullBytes);

    final splitAt = fullBytes.length ~/ 2;
    final savePath = p.join(tempDir.path, 'download.bin');
    File(savePath).writeAsBytesSync(fullBytes.sublist(0, splitAt));

    var lastReceived = 0;
    await client.fetchFile(
      target: device,
      requesterId: 'me',
      remotePath: 'download.bin',
      savePath: savePath,
      resumeFrom: splitAt,
      onProgress: (received, total) {
        lastReceived = received;
        expect(total, fullBytes.length);
      },
    );
    expect(lastReceived, fullBytes.length);
    expect(File(savePath).readAsBytesSync(), equals(fullBytes));
  });

  test('a full (non-resumed) fetch still works exactly as before', () async {
    final fullBytes = Uint8List.fromList(List.generate(50 * 1024, (i) => i % 256));
    final sharedDir = Directory(p.join(tempDir.path, 'shared'))..createSync();
    File(p.join(sharedDir.path, 'whole.bin')).writeAsBytesSync(fullBytes);
    final savePath = p.join(tempDir.path, 'whole.bin');

    await client.fetchFile(
      target: device,
      requesterId: 'me',
      remotePath: 'whole.bin',
      savePath: savePath,
      onProgress: (_, _) {},
    );
    expect(File(savePath).readAsBytesSync(), equals(fullBytes));
  });
}
