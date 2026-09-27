import 'dart:io';

/// This device's non-loopback IPv4 addresses — what someone would type
/// into another device's "Add device by IP" dialog to reach it directly.
/// Usually just one, but a device with both Wi-Fi and Ethernet active can
/// have more than one; callers should show all of them rather than guess.
Future<List<String>> localIpAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final iface in interfaces)
        for (final addr in iface.addresses) addr.address,
    ];
  } catch (_) {
    return [];
  }
}

/// True for an RFC 1918 private-LAN address (10.0.0.0/8, 172.16.0.0/12,
/// 192.168.0.0/16). A phone with mobile data on alongside Wi-Fi also
/// carries a carrier-NAT address (RFC 6598, 100.64.0.0/10) that isn't
/// reachable from anything else on the LAN — scanning that subnet
/// instead of the real one silently finds nothing.
bool isPrivateLanAddress(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!, b = parts[1]!;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// The best address to use as "this device's LAN address" — the first
/// private-LAN one if there is any, otherwise just the first address.
Future<String?> primaryLanAddress() async {
  final addresses = await localIpAddresses();
  if (addresses.isEmpty) return null;
  return addresses.firstWhere(isPrivateLanAddress, orElse: () => addresses.first);
}
