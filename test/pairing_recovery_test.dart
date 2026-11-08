import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/device.dart';
import 'package:tether/models/transfer.dart';
import 'package:tether/services/transfer_client.dart';
import 'package:tether/services/transfer_server.dart';

/// Covers the protocol pieces that keep the two halves of a pairing from
/// drifting apart: recovering a pairing decision whose reply was lost,
/// asking a peer whether it still trusts us, and the unpair hint. Runs a
/// real TransferServer/TransferClient pair over loopback TLS, headless.
SecurityContext _testSecurityContext() {
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
  late TransferServer server;
  late Device device;
  late Set<String> trusted;
  late List<String> unpairHints;
  // How the fake "user" answers a pair request, and how long they take.
  late bool acceptPairing;
  late Duration decisionDelay;

  setUp(() async {
    trusted = {};
    unpairHints = [];
    acceptPairing = true;
    decisionDelay = Duration.zero;
    server = TransferServer(
      onIncomingRequest: (req) => req.decision.complete(true),
      onIncomingPairRequest: (req) => Timer(decisionDelay, () => req.decision.complete(acceptPairing)),
      onFileSink: (request, fileIndex, meta, data, {int resumeFrom = 0}) async {},
      onUploadStatus: (transferId, fileIndex) async => 0,
      isTrusted: trusted.contains,
      onListDir: (path) async => [],
      onOpenFile: (relativePath) => File(relativePath),
      onClipboard: (_) {},
      onUnpairHint: unpairHints.add,
      selfId: 'receiver-id',
      selfName: () => 'Receiver',
      selfPlatform: 'test',
      securityContext: _testSecurityContext(),
    );
    await server.start();
    device = Device(
      id: 'receiver-id',
      name: 'Receiver',
      platform: 'test',
      address: '127.0.0.1',
      port: server.port,
      lastSeen: DateTime.now(),
    );
  });

  tearDown(() => server.stop());

  Future<PairResult> pair(TransferClient client, {String pairId = 'pair-1'}) =>
      client.sendPairRequest(target: device, selfId: 'me', selfName: 'Me', code: '123456', pairId: pairId);

  group('pairing whose reply is lost', () {
    test('still learns an accept that lands after the request gave up waiting', () async {
      // The requester stops waiting after 1s; the other user takes 2s.
      decisionDelay = const Duration(seconds: 2);
      final result = await pair(TransferClient(offerTimeout: const Duration(seconds: 1)));
      expect(result.accepted, isTrue);
      expect(result.certFingerprint, isNotEmpty);
    });

    test('still learns a decline that lands after the request gave up waiting', () async {
      decisionDelay = const Duration(seconds: 2);
      acceptPairing = false;
      final result = await pair(TransferClient(offerTimeout: const Duration(seconds: 1)));
      expect(result.accepted, isFalse);
    });

    test('an unreachable peer is still a plain failure', () async {
      final gone = Device(id: 'x', name: 'Gone', platform: 'test', address: '127.0.0.1', port: 1, lastSeen: DateTime.now());
      await expectLater(
        TransferClient(offerTimeout: const Duration(seconds: 1))
            .sendPairRequest(target: gone, selfId: 'me', selfName: 'Me', code: '1', pairId: 'p'),
        throwsA(anything),
      );
    });
  });

  group('trust check', () {
    late TransferClient client;
    late String fingerprint;

    setUp(() async {
      client = TransferClient();
      fingerprint = (await client.probeDevice(address: '127.0.0.1', port: server.port)).certFingerprint;
    });

    test('reports whether the peer trusts us', () async {
      trusted.add('me');
      expect(await client.checkTrust(target: device, selfId: 'me', expectedFingerprint: fingerprint), isTrue);
      trusted.clear();
      expect(await client.checkTrust(target: device, selfId: 'me', expectedFingerprint: fingerprint), isFalse);
    });

    test('says nothing — never "no" — when the certificate is not the pinned one', () async {
      trusted.add('me');
      expect(await client.checkTrust(target: device, selfId: 'me', expectedFingerprint: 'not-the-fingerprint'), isNull);
    });

    test('says nothing when the peer is unreachable', () async {
      final gone = Device(id: 'x', name: 'Gone', platform: 'test', address: '127.0.0.1', port: 1, lastSeen: DateTime.now());
      expect(await client.checkTrust(target: gone, selfId: 'me', expectedFingerprint: fingerprint), isNull);
    });
  });

  test('unpair hint reaches the peer with the sender id', () async {
    await TransferClient().sendUnpairHint(target: device, selfId: 'me');
    expect(unpairHints, ['me']);
  });

  group('offer response', () {
    Future<TransferOfferResult> offer() => TransferClient().sendOffer(
          target: device,
          selfId: 'me',
          selfName: 'Me',
          transferId: 't',
          files: [const FileMeta(name: 'a.txt', size: 1)],
          pairingCode: '123456',
        );

    test('tells the sender when the receiver trusts it', () async {
      trusted.add('me');
      final result = await offer();
      expect(result.accepted, isTrue);
      expect(result.peerTrustsUs, isTrue);
    });

    test('does not claim trust the receiver never granted', () async {
      final result = await offer();
      expect(result.accepted, isTrue);
      expect(result.peerTrustsUs, isFalse);
    });
  });
}
