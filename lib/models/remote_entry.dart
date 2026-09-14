/// One file or folder entry returned by a peer's `/browse` endpoint.
class RemoteEntry {
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;

  const RemoteEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'isDir': isDir,
        'size': size,
        'modified': modified.toIso8601String(),
      };

  factory RemoteEntry.fromJson(Map<String, dynamic> json) => RemoteEntry(
        name: json['name'] as String,
        isDir: json['isDir'] as bool,
        size: json['size'] as int,
        modified: DateTime.parse(json['modified'] as String),
      );
}
