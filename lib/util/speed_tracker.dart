import '../models/transfer.dart';

/// Turns raw progress callbacks (which fire once per chunk — dozens of
/// times a second on a fast LAN) into a smoothed speed/ETA pair that's
/// actually readable, sampled at a fixed rate rather than recomputed on
/// every chunk. One instance covers a single transfer *attempt*: construct
/// a fresh one for each retry/resume so a stall's dead time never gets
/// counted as part of the measured throughput.
class SpeedTracker {
  static const _sampleInterval = Duration(milliseconds: 250);
  static const _emaAlpha = 0.3;

  DateTime? _lastSampleAt;
  int _lastSampleBytes;
  double? _smoothedBps;

  SpeedTracker(int startBytes) : _lastSampleBytes = startBytes;

  /// Feeds the latest cumulative [bytesSoFar] out of [totalBytes] and, at
  /// most 4 times a second, updates [record]'s `speedBytesPerSec`/`eta`.
  /// Returns whether it did — callers should skip their own
  /// `notifyListeners()` when this is false, so the UI isn't rebuilt for
  /// every single chunk.
  bool sample(int bytesSoFar, int totalBytes, TransferRecord record) {
    final now = DateTime.now();
    final last = _lastSampleAt;
    if (last != null && now.difference(last) < _sampleInterval) return false;

    if (last != null) {
      final elapsedSeconds = now.difference(last).inMicroseconds / Duration.microsecondsPerSecond;
      final instantBps = elapsedSeconds > 0 ? (bytesSoFar - _lastSampleBytes) / elapsedSeconds : 0.0;
      _smoothedBps = _smoothedBps == null ? instantBps : (_emaAlpha * instantBps + (1 - _emaAlpha) * _smoothedBps!);
    }
    _lastSampleAt = now;
    _lastSampleBytes = bytesSoFar;

    record.speedBytesPerSec = _smoothedBps;
    final remaining = totalBytes - bytesSoFar;
    record.eta = (_smoothedBps != null && _smoothedBps! > 0) ? Duration(seconds: (remaining / _smoothedBps!).round()) : null;
    return true;
  }
}
