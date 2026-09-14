import 'dart:async';

enum PairingStatus { waiting, accepted, declined, failed }

/// A pairing request from a remote device, awaiting local accept/decline.
///
/// Unlike [IncomingTransferRequest], accepting this always results in
/// mutual trust — there's no separate "trust after" checkbox, since
/// pairing's whole purpose is establishing that trust.
class IncomingPairRequest {
  final String requesterId;
  final String requesterName;
  final String requesterAddress;
  final String code;
  final Completer<bool> decision = Completer<bool>();

  IncomingPairRequest({
    required this.requesterId,
    required this.requesterName,
    required this.requesterAddress,
    required this.code,
  });
}

/// Local state for a pairing attempt this device initiated.
class PairingAttempt {
  final String id;
  final String peerId;
  final String peerName;
  final String code;
  PairingStatus status;
  String? error;

  PairingAttempt({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.code,
    this.status = PairingStatus.waiting,
    this.error,
  });
}
