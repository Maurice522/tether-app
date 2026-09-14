import 'dart:math';

/// A short human-comparable code shown on both ends of a new (untrusted)
/// pairing so the user can visually confirm sender and receiver agree
/// before accepting a transfer.
String generatePairingCode() {
  final rand = Random.secure();
  final n = rand.nextInt(900000) + 100000; // 6 digits, no leading zero
  return n.toString();
}
