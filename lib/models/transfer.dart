import 'dart:async';

enum TransferDirection { incoming, outgoing }

enum TransferStatus {
  pendingApproval,
  transferring,
  completed,
  declined,
  failed,
  canceled,
}

/// Metadata describing a single file within a transfer offer.
class FileMeta {
  final String name;
  final int size;

  const FileMeta({required this.name, required this.size});

  Map<String, dynamic> toJson() => {'name': name, 'size': size};

  factory FileMeta.fromJson(Map<String, dynamic> json) => FileMeta(
        name: json['name'] as String,
        size: json['size'] as int,
      );
}

/// An offer from a remote sender, awaiting local accept/decline.
///
/// [decision] is completed by the UI (or auto-accept logic) with `true`
/// to accept the transfer or `false` to decline it. The HTTP handler that
/// created this request awaits it directly, so the sender's request stays
/// open until the local user responds.
class IncomingTransferRequest {
  final String transferId;
  final String senderId;
  final String senderName;
  final String senderAddress;
  final List<FileMeta> files;
  final String pairingCode;
  final Completer<bool> decision = Completer<bool>();

  IncomingTransferRequest({
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.senderAddress,
    required this.files,
    required this.pairingCode,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
}

/// A row in transfer history / the active-transfers list shown in the UI.
class TransferRecord {
  final String id;
  final TransferDirection direction;
  final String peerName;
  final String peerId;
  final List<FileMeta> files;
  TransferStatus status;
  int bytesTransferred;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? error;

  /// Set on outgoing transfers to an untrusted peer so the sender's UI can
  /// display the same code shown in the receiver's accept dialog.
  final String? pairingCode;

  /// Actual on-disk path(s) for an incoming transfer's saved files, in
  /// file order — lets the UI reveal exactly what was written, since a
  /// name clash may have renamed it (see uniqueSavePath).
  final List<String> savedPaths;

  TransferRecord({
    required this.id,
    required this.direction,
    required this.peerName,
    required this.peerId,
    required this.files,
    this.status = TransferStatus.pendingApproval,
    this.bytesTransferred = 0,
    DateTime? startedAt,
    this.finishedAt,
    this.error,
    this.pairingCode,
    List<String>? savedPaths,
  })  : startedAt = startedAt ?? DateTime.now(),
        savedPaths = savedPaths ?? [];

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  double get progress => totalBytes == 0 ? 0 : bytesTransferred / totalBytes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'direction': direction.name,
        'peerName': peerName,
        'peerId': peerId,
        'files': files.map((f) => f.toJson()).toList(),
        'status': status.name,
        'bytesTransferred': bytesTransferred,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'error': error,
        'savedPaths': savedPaths,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
        id: json['id'] as String,
        direction: TransferDirection.values.byName(json['direction'] as String),
        peerName: json['peerName'] as String,
        peerId: json['peerId'] as String,
        files: (json['files'] as List)
            .map((f) => FileMeta.fromJson(f as Map<String, dynamic>))
            .toList(),
        status: TransferStatus.values.byName(json['status'] as String),
        bytesTransferred: json['bytesTransferred'] as int,
        startedAt: DateTime.parse(json['startedAt'] as String),
        finishedAt: json['finishedAt'] == null ? null : DateTime.parse(json['finishedAt'] as String),
        error: json['error'] as String?,
        savedPaths: (json['savedPaths'] as List?)?.map((e) => e as String).toList(),
      );
}
