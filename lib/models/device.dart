/// A peer discovered on the LAN via [DiscoveryService].
class Device {
  final String id;
  final String name;
  final String platform;
  final String address;
  final int port;
  final DateTime lastSeen;

  const Device({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  Device copyWith({String? address, int? port, DateTime? lastSeen}) => Device(
        id: id,
        name: name,
        platform: platform,
        address: address ?? this.address,
        port: port ?? this.port,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  @override
  bool operator ==(Object other) => other is Device && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Device($name @ $address:$port)';
}
