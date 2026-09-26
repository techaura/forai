import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';

import '../core/crypto/kwvlock.dart';
import '../core/vault/vault_node.dart';

class LockKeyRef {
  final VaultNode node;
  final Uint8List? publicKey;
  final Uint8List? privateKey;

  const LockKeyRef({
    required this.node,
    required this.publicKey,
    required this.privateKey,
  });

  String get label => node.name;
  bool get canEncrypt => publicKey != null;
  bool get canDecrypt => privateKey != null;
}

class PickedLockedFile {
  final String name;
  final Uint8List bytes;
  final Uri uri;

  const PickedLockedFile({
    required this.name,
    required this.bytes,
    required this.uri,
  });
}

class LockFileService {
  static List<LockKeyRef> findX25519Keys(VaultNode root) {
    final result = <LockKeyRef>[];

    void walk(VaultNode node) {
      final knownX25519File = node.files.any((artifact) {
        final name = artifact.name.toLowerCase();
        return name == 'kwvlock-public.key' ||
            name == 'kwvlock-private.key' ||
            name == 'wireguard-public.key' ||
            name == 'wireguard-private.key';
      });
      final declaredX25519 = node.meta['algorithm']?.toUpperCase() == 'X25519';
      if (!node.isGroup && (declaredX25519 || knownX25519File)) {
        final publicArtifact = _findArtifact(node, 'public');
        final privateArtifact = _findArtifact(node, 'private');
        Uint8List? publicKey;
        Uint8List? privateKey;
        try {
          if (publicArtifact != null) publicKey = _decodeKey(node, publicArtifact);
          if (privateArtifact != null) privateKey = _decodeKey(node, privateArtifact);
        } on FormatException {
          // Malformed/imported entries are not offered as encryption keys.
        }
        if ((publicKey?.length == 32) || (privateKey?.length == 32)) {
          result.add(
            LockKeyRef(
              node: node,
              publicKey: publicKey?.length == 32 ? publicKey : null,
              privateKey: privateKey?.length == 32 ? privateKey : null,
            ),
          );
        }
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(root);
    return result;
  }

  static Future<PickedLockedFile?> pickLockedFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Open encrypted KWVLOCK file',
      type: FileType.custom,
      allowedExtensions: const ['kwvlock'],
    );
    if (file == null) return null;
    return PickedLockedFile(
      name: file.name,
      bytes: await file.readAsBytes(),
      uri: file.uri,
    );
  }

  static Future<String?> encryptPickedFile({required LockKeyRef recipient}) async {
    final publicKey = recipient.publicKey;
    if (publicKey == null) throw StateError('Selected entry has no X25519 public key');

    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose file to encrypt',
      type: FileType.any,
    );
    if (file == null) return null;

    final archive = Archive()
      ..add(ArchiveFile.bytes(file.name, await file.readAsBytes()));
    final zip = ZipEncoder().encodeBytes(archive, level: DeflateLevel.bestSpeed);
    final locked = await KwvLockCrypto.encrypt(
      payload: zip,
      recipientPublicKey: publicKey,
    );

    if (file.uri.scheme == 'file') {
      final source = File.fromUri(file.uri);
      final output = _uniqueFile('${source.path}.kwvlock');
      await output.writeAsBytes(locked, flush: true);
      return output.path;
    }

    final saved = await FilePicker.saveFile(
      dialogTitle: 'Save encrypted file',
      fileName: '${file.name}.kwvlock',
      bytes: locked,
      type: FileType.custom,
      allowedExtensions: const ['kwvlock'],
      mimeType: 'application/vnd.keywallet.locked',
    );
    return saved?.toString();
  }

  static Future<String?> encryptPickedDirectory({required LockKeyRef recipient}) async {
    final publicKey = recipient.publicKey;
    if (publicKey == null) throw StateError('Selected entry has no X25519 public key');

    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose directory to encrypt',
    );
    if (selected == null) return null;

    final directory = Directory(selected);
    if (!directory.existsSync()) throw StateError('Selected directory is not accessible');
    final archive = await _archiveDirectory(directory);
    final zip = ZipEncoder().encodeBytes(archive, level: DeflateLevel.bestSpeed);
    final locked = await KwvLockCrypto.encrypt(
      payload: zip,
      recipientPublicKey: publicKey,
    );

    final output = _uniqueFile('${_withoutTrailingSeparators(directory.path)}.kwvlock');
    await output.writeAsBytes(locked, flush: true);
    return output.path;
  }

  static Future<String> unlockToSiblingDirectory({
    required PickedLockedFile picked,
    required LockKeyRef recipient,
  }) async {
    final privateKey = recipient.privateKey;
    if (privateKey == null) throw StateError('Selected entry has no X25519 private key');

    final zipBytes = await KwvLockCrypto.decrypt(
      locked: picked.bytes,
      recipientPrivateKey: privateKey,
    );
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);

    final base = picked.name.toLowerCase().endsWith('.kwvlock')
        ? picked.name.substring(0, picked.name.length - '.kwvlock'.length)
        : picked.name;

    Directory parent;
    if (picked.uri.scheme == 'file') {
      parent = File.fromUri(picked.uri).parent;
    } else {
      final destination = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose destination for unlocked content',
      );
      if (destination == null) {
        throw FileSystemException('Unlock destination was not selected');
      }
      parent = Directory(destination);
    }

    final output = _uniqueDirectory(_join(parent.path, '$base-unlocked'));
    await output.create(recursive: true);
    extractArchivePreservingDirectories(archive, output);
    return output.path;
  }


  /// Extracts an archive while preserving explicit directory entries, including
  /// empty directories. Paths are validated to prevent archive traversal and
  /// symbolic links are rejected.
  static void extractArchivePreservingDirectories(
    Archive archive,
    Directory output,
  ) {
    output.createSync(recursive: true);

    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw const FormatException('Symbolic links are not supported in KWVLOCK archives');
      }

      final relative = _safeArchivePath(entry.name);
      if (relative.isEmpty) continue;
      final targetPath = _joinArchivePath(output.path, relative);

      if (entry.isDirectory) {
        Directory(targetPath).createSync(recursive: true);
        continue;
      }

      final target = File(targetPath);
      target.parent.createSync(recursive: true);
      final bytes = entry.readBytes();
      if (bytes == null) {
        throw FormatException('Unable to read archive entry: ${entry.name}');
      }
      target.writeAsBytesSync(bytes, flush: true);
    }
  }

  static String _safeArchivePath(String name) {
    var normalized = name.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.isEmpty) return '';
    if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw FormatException('Unsafe absolute archive path: $name');
    }

    final parts = <String>[];
    for (final part in normalized.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        throw FormatException('Unsafe archive traversal path: $name');
      }
      parts.add(part);
    }
    return parts.join('/');
  }

  static String _joinArchivePath(String root, String relative) {
    var out = root;
    for (final part in relative.split('/')) {
      out = _join(out, part);
    }
    return out;
  }

  static Future<List<LockKeyRef>> matchingPrivateKeys({
    required Uint8List locked,
    required List<LockKeyRef> keys,
  }) async {
    final expected = KwvLockCrypto.recipientIdFromContainer(locked);
    final matches = <LockKeyRef>[];
    for (final key in keys) {
      if (!key.canDecrypt || key.publicKey == null) continue;
      final actual = await KwvLockCrypto.recipientId(key.publicKey!);
      if (_sameBytes(expected, actual)) matches.add(key);
    }
    return matches;
  }

  static VaultArtifact? _findArtifact(VaultNode node, String role) {
    for (final artifact in node.files) {
      if (artifact.name.toLowerCase().contains(role)) return artifact;
    }
    return null;
  }

  static Uint8List _decodeKey(VaultNode node, VaultArtifact artifact) {
    final text = utf8.decode(artifact.data, allowMalformed: false).trim();
    final encoding = node.meta['encoding']?.toLowerCase();
    if (encoding == 'hex') return _decodeHex(text);
    if (encoding == 'base64url') {
      return Uint8List.fromList(base64Url.decode(_padBase64(text)));
    }
    final artifactName = artifact.name.toLowerCase();
    if (encoding == 'base64' ||
        node.kind == 'wireguard' ||
        node.kind == 'file-lock' ||
        artifactName.startsWith('kwvlock-') ||
        artifactName.startsWith('wireguard-')) {
      return Uint8List.fromList(base64Decode(text));
    }

    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) return _decodeHex(text);
    try {
      return Uint8List.fromList(base64Decode(text));
    } on FormatException {
      return Uint8List.fromList(base64Url.decode(_padBase64(text)));
    }
  }

  static Uint8List _decodeHex(String value) {
    if (value.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
      throw const FormatException('Invalid hex key');
    }
    final out = Uint8List(value.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _padBase64(String value) {
    final mod = value.length % 4;
    return mod == 0 ? value : value.padRight(value.length + (4 - mod), '=');
  }

  static Future<Archive> _archiveDirectory(Directory root) async {
    final archive = Archive();
    final rootPath = _withoutTrailingSeparators(root.path);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) continue;
      var relative = entity.path.substring(rootPath.length);
      while (relative.startsWith('/') || relative.startsWith('\\')) {
        relative = relative.substring(1);
      }
      relative = relative.replaceAll('\\', '/');
      if (relative.isEmpty) continue;
      if (entity is Directory) {
        archive.add(ArchiveFile.directory('$relative/'));
      } else if (entity is File) {
        archive.add(ArchiveFile.bytes(relative, await entity.readAsBytes()));
      }
    }
    return archive;
  }

  static File _uniqueFile(String path) {
    var candidate = File(path);
    if (!candidate.existsSync()) return candidate;
    final lower = path.toLowerCase();
    final hasLockExtension = lower.endsWith('.kwvlock');
    final stem = hasLockExtension ? path.substring(0, path.length - 8) : path;
    final extension = hasLockExtension ? '.kwvlock' : '';
    var index = 2;
    while (true) {
      candidate = File('$stem-$index$extension');
      if (!candidate.existsSync()) return candidate;
      index++;
    }
  }

  static Directory _uniqueDirectory(String path) {
    var candidate = Directory(path);
    if (!candidate.existsSync()) return candidate;
    var index = 2;
    while (true) {
      candidate = Directory('$path-$index');
      if (!candidate.existsSync()) return candidate;
      index++;
    }
  }

  static String _join(String parent, String child) {
    if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
    return '$parent${Platform.pathSeparator}$child';
  }

  static String _withoutTrailingSeparators(String value) {
    var out = value;
    while (out.length > 1 && (out.endsWith('/') || out.endsWith('\\'))) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
