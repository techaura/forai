import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../crypto/kwv1_crypto.dart';
import 'vault.dart';

class OpenedVault {
  final Vault vault;
  final int revision;
  final int iterations;

  const OpenedVault({
    required this.vault,
    required this.revision,
    required this.iterations,
  });
}

/// Persistent encrypted vault storage shared by Windows and Android builds.
///
/// Only KWV1 bytes are written to disk. Plaintext vault JSON is never stored.
class VaultRepository {
  static const String localFileName = 'vault.kwvault';

  Future<File> _vaultFile() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$localFileName');
  }

  Future<bool> exists() async => (await _vaultFile()).exists();

  Future<Uint8List> readRaw() async {
    final file = await _vaultFile();
    if (!await file.exists()) {
      throw const FileSystemException('Local KeyWallet vault does not exist');
    }
    return Uint8List.fromList(await file.readAsBytes());
  }

  Future<OpenedVault> unlock(String password) async {
    final raw = await readRaw();
    final opened = await Kwv1Crypto.decrypt(raw, password);
    return OpenedVault(
      vault: opened.vault,
      revision: opened.container.revision,
      iterations: opened.container.iterations,
    );
  }

  Future<OpenedVault> create(String password) async {
    if (password.isEmpty) {
      throw ArgumentError('Master password must not be empty');
    }
    final vault = Vault.empty();
    final raw = await Kwv1Crypto.encrypt(vault, password, revision: 1);
    await _writeRawSafely(raw);
    return OpenedVault(
      vault: vault,
      revision: 1,
      iterations: Kwv1Crypto.currentIterations,
    );
  }

  /// Validates [raw] with [password] before replacing the local vault.
  Future<OpenedVault> importPortable(Uint8List raw, String password) async {
    final opened = await Kwv1Crypto.decrypt(raw, password);
    await _writeRawSafely(raw);
    return OpenedVault(
      vault: opened.vault,
      revision: opened.container.revision,
      iterations: opened.container.iterations,
    );
  }

  /// Re-encrypts and persists a modified vault.
  ///
  /// This is not used by the read-only Step 2 UI yet, but is the write path for
  /// the next stage. Revision is incremented here rather than in widgets.
  Future<OpenedVault> save({
    required Vault vault,
    required String password,
    required int previousRevision,
  }) async {
    final revision = previousRevision + 1;
    vault.updatedAt = DateTime.now().toUtc().toIso8601String();
    final raw = await Kwv1Crypto.encrypt(
      vault,
      password,
      revision: revision,
    );
    await _writeRawSafely(raw);
    return OpenedVault(
      vault: vault,
      revision: revision,
      iterations: Kwv1Crypto.currentIterations,
    );
  }

  Future<void> _writeRawSafely(Uint8List bytes) async {
    final target = await _vaultFile();
    final temp = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');

    if (await temp.exists()) await temp.delete();
    await temp.writeAsBytes(bytes, flush: true);

    var movedOldToBackup = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) {
        await target.rename(backup.path);
        movedOldToBackup = true;
      }
      await temp.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      if (movedOldToBackup &&
          await backup.exists() &&
          !await target.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
