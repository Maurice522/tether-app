import 'package:flutter_test/flutter_test.dart';
import 'package:tether/models/transfer.dart';
import 'package:tether/util/speed_tracker.dart';

TransferRecord _record() => TransferRecord(
      id: 't',
      direction: TransferDirection.outgoing,
      peerName: 'peer',
      peerId: 'peer-id',
      files: [const FileMeta(name: 'f', size: 1000000)],
    );

void main() {
  test('throttles updates to the sample interval', () {
    final record = _record();
    final tracker = SpeedTracker(0);
    expect(tracker.sample(1000, 1000000, record), isTrue); // first sample always applies
    expect(tracker.sample(2000, 1000000, record), isFalse); // too soon after
  });

  test('computes a positive speed and a shrinking ETA once time has passed', () async {
    final record = _record();
    final tracker = SpeedTracker(0);
    tracker.sample(0, 1000000, record);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    final applied = tracker.sample(250000, 1000000, record);
    expect(applied, isTrue);
    expect(record.speedBytesPerSec, isNotNull);
    expect(record.speedBytesPerSec, greaterThan(0));
    expect(record.eta, isNotNull);
  });

  test('reports no speed when zero time has elapsed against a fresh start', () {
    final record = _record();
    final tracker = SpeedTracker(500);
    tracker.sample(500, 1000000, record);
    expect(record.speedBytesPerSec, isNull);
    expect(record.eta, isNull);
  });
}
