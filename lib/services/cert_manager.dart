import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/net_log.dart';

/// This device's persistent TLS identity: a self-signed certificate and
/// its private key, generated once and reused for the app's lifetime (and
/// across restarts, so a peer's pinned fingerprint of this device stays
/// valid). There's no CA — every device is its own certificate authority
/// of one, and trust is established the same way it already was before
/// TLS existed: a human comparing a pairing code, now additionally pinning
/// the fingerprint of the certificate seen during that exchange.
class CertManager {
  static const _certFileName = 'device_cert.pem';
  static const _keyFileName = 'device_key.pem';
  static const _validityDays = 3650;

  final SecurityContext securityContext;

  CertManager._(this.securityContext);

  static Future<CertManager> load() async {
    final dir = await getApplicationSupportDirectory();
    final certFile = File(p.join(dir.path, _certFileName));
    final keyFile = File(p.join(dir.path, _keyFileName));

    String certPem;
    String keyPem;
    if (await certFile.exists() && await keyFile.exists()) {
      certPem = await certFile.readAsString();
      keyPem = await keyFile.readAsString();
    } else {
      netLog('cert', 'no device identity found, generating one');
      final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
      final privateKey = pair.privateKey as RSAPrivateKey;
      final publicKey = pair.publicKey as RSAPublicKey;
      final csr = X509Utils.generateRsaCsrPem({'CN': 'tether-device'}, privateKey, publicKey);
      certPem = X509Utils.generateSelfSignedCertificate(privateKey, csr, _validityDays);
      keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
      await dir.create(recursive: true);
      await certFile.writeAsString(certPem);
      await keyFile.writeAsString(keyPem);
      netLog('cert', 'device identity generated and saved to ${dir.path}');
    }

    final securityContext = SecurityContext()
      ..useCertificateChainBytes(Uint8List.fromList(certPem.codeUnits))
      ..usePrivateKeyBytes(Uint8List.fromList(keyPem.codeUnits));

    return CertManager._(securityContext);
  }
}
