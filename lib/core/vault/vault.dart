import 'dart:convert';
import 'dart:typed_data';

import 'vault_node.dart';

class Vault {
  final int version;
  String createdAt;
  String updatedAt;
  VaultNode root;

  /// Unknown future top-level fields are retained for compatible round trips.
  final Map<String, dynamic> extra;

  Vault({
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.root,
    Map<String, dynamic>? extra,
  }) : extra = Map<String, dynamic>.from(extra ?? const <String, dynamic>{});

  factory Vault.empty() {
    final now = DateTime.now().toUtc().toIso8601String();
    return Vault(
      version: 1,
      createdAt: now,
      updatedAt: now,
      root: VaultNode(
        id: 'root',
        name: 'WalletWalley',
        type: 'group',
      ),
    );
  }

  factory Vault.fromJson(Map<String, dynamic> source) {
    final extra = Map<String, dynamic>.from(source)
      ..remove('version')
      ..remove('created_at')
      ..remove('updated_at')
      ..remove('root');

    final rootValue = source['root'];
    if (rootValue is! Map) {
      throw const FormatException('Vault root is missing');
    }

    final rootMap = rootValue.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    final vault = Vault(
      version: source['version'] is int ? source['version'] as int : 0,
      createdAt: source['created_at'] is String ? source['created_at'] as String : '',
      updatedAt: source['updated_at'] is String ? source['updated_at'] as String : '',
      root: VaultNode.fromJson(rootMap),
      extra: extra,
    );
    vault.validate();
    return vault;
  }

  factory Vault.fromUtf8Bytes(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map) {
      throw const FormatException('Vault JSON root must be an object');
    }
    return Vault.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  void validate() {
    if (version < 1) {
      throw const FormatException('Unsupported vault version');
    }
    if (root.type != 'group') {
      throw const FormatException('Vault root must be a group');
    }
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{...extra};
    out['version'] = version;
    out['created_at'] = createdAt;
    out['updated_at'] = updatedAt;
    out['root'] = root.toJson();
    return out;
  }

  Uint8List toUtf8Bytes() {
    return Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  }
}
