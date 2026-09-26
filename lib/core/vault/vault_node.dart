import 'dart:convert';
import 'dart:typed_data';

Map<String, dynamic> _jsonMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.from(value);
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) {
    return <String, String>{};
  }
  final out = <String, String>{};
  for (final entry in value.entries) {
    if (entry.value is String) {
      out[entry.key.toString()] = entry.value as String;
    }
  }
  return out;
}

/// One file/artifact stored in a KeyWallet entry.
class VaultArtifact {
  final String name;
  final Uint8List data;
  final String contentType;
  final String note;
  final Map<String, String> meta;

  /// Unknown future fields are retained for forward-compatible round trips.
  final Map<String, dynamic> extra;

  VaultArtifact({
    required this.name,
    required Uint8List data,
    this.contentType = '',
    this.note = '',
    Map<String, String>? meta,
    Map<String, dynamic>? extra,
  })  : data = Uint8List.fromList(data),
        meta = Map<String, String>.from(meta ?? const <String, String>{}),
        extra = Map<String, dynamic>.from(extra ?? const <String, dynamic>{});

  factory VaultArtifact.fromJson(Map<String, dynamic> source) {
    final extra = Map<String, dynamic>.from(source)
      ..remove('name')
      ..remove('data')
      ..remove('content_type')
      ..remove('note')
      ..remove('meta');

    final encodedData = source['data'];
    Uint8List decoded;
    if (encodedData is String) {
      try {
        decoded = Uint8List.fromList(base64Decode(encodedData));
      } on FormatException {
        throw FormatException('Invalid Base64 in artifact ${source['name'] ?? ''}');
      }
    } else {
      decoded = Uint8List(0);
    }

    return VaultArtifact(
      name: source['name'] is String ? source['name'] as String : '',
      data: decoded,
      contentType:
          source['content_type'] is String ? source['content_type'] as String : '',
      note: source['note'] is String ? source['note'] as String : '',
      meta: _stringMap(source['meta']),
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{...extra};
    out['name'] = name;
    out['data'] = base64Encode(data);
    if (contentType.isNotEmpty) out['content_type'] = contentType;
    if (note.isNotEmpty) out['note'] = note;
    if (meta.isNotEmpty) out['meta'] = Map<String, String>.from(meta);
    return out;
  }
}

/// Recursive KeyWallet tree node: either a group or an entry.
class VaultNode {
  final String id;
  String name;
  final String type; // group | entry
  String kind;
  final Map<String, String> meta;
  final List<VaultArtifact> files;
  final List<VaultNode> children;

  /// Unknown future fields are retained for forward-compatible round trips.
  final Map<String, dynamic> extra;

  VaultNode({
    required this.id,
    required this.name,
    required this.type,
    this.kind = '',
    Map<String, String>? meta,
    List<VaultArtifact>? files,
    List<VaultNode>? children,
    Map<String, dynamic>? extra,
  })  : meta = Map<String, String>.from(meta ?? const <String, String>{}),
        files = List<VaultArtifact>.from(files ?? const <VaultArtifact>[]),
        children = List<VaultNode>.from(children ?? const <VaultNode>[]),
        extra = Map<String, dynamic>.from(extra ?? const <String, dynamic>{});

  bool get isGroup => type == 'group';
  bool get isEntry => type == 'entry';

  factory VaultNode.fromJson(Map<String, dynamic> source) {
    final extra = Map<String, dynamic>.from(source)
      ..remove('id')
      ..remove('name')
      ..remove('type')
      ..remove('kind')
      ..remove('meta')
      ..remove('files')
      ..remove('children');

    final rawFiles = source['files'];
    final files = <VaultArtifact>[];
    if (rawFiles is List) {
      for (final item in rawFiles) {
        if (item is Map) {
          files.add(VaultArtifact.fromJson(_jsonMap(item)));
        }
      }
    }

    final rawChildren = source['children'];
    final children = <VaultNode>[];
    if (rawChildren is List) {
      for (final item in rawChildren) {
        if (item is Map) {
          children.add(VaultNode.fromJson(_jsonMap(item)));
        }
      }
    }

    return VaultNode(
      id: source['id'] is String ? source['id'] as String : '',
      name: source['name'] is String ? source['name'] as String : '',
      type: source['type'] is String ? source['type'] as String : '',
      kind: source['kind'] is String ? source['kind'] as String : '',
      meta: _stringMap(source['meta']),
      files: files,
      children: children,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{...extra};
    out['id'] = id;
    out['name'] = name;
    out['type'] = type;
    if (kind.isNotEmpty) out['kind'] = kind;
    if (meta.isNotEmpty) out['meta'] = Map<String, String>.from(meta);
    if (files.isNotEmpty) {
      out['files'] = files.map((artifact) => artifact.toJson()).toList();
    }
    if (children.isNotEmpty) {
      out['children'] = children.map((child) => child.toJson()).toList();
    }
    return out;
  }
}
