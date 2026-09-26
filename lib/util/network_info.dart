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
