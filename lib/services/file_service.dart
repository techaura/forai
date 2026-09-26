import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

class PickedVaultFile {
  final String name;
  final Uint8List bytes;

  const PickedVaultFile({required this.name, required this.bytes});
}

class PickedGenericFile {
  final String name;
  final Uint8List bytes;

  const PickedGenericFile({required this.name, required this.bytes});
}

class FileService {
  static bool isVaultFileName(String name) =>
      name.toLowerCase().endsWith('.kwvault');

  static Future<PickedVaultFile?> pickVault({
    required String dialogTitle,
  }) async {
    final file = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const ['kwvault'],
    );
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    return PickedVaultFile(name: file.name, bytes: bytes);
  }

  static Future<PickedGenericFile?> pickAnyFile({
    required String dialogTitle,
  }) async {
    final file = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.any,
    );
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    return PickedGenericFile(name: file.name, bytes: bytes);
  }

  static Future<Uri?> saveVault(
    Uint8List bytes, {
    required String dialogTitle,
  }) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final fileName = 'WalletWalley-'
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.kwvault';

    return FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/vnd.keywallet.vault',
      type: FileType.custom,
      allowedExtensions: const ['kwvault'],
    );
  }

  static Future<Uri?> saveArtifact({
    required String fileName,
    required Uint8List bytes,
    required String dialogTitle,
  }) {
    return FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
      type: FileType.any,
    );
  }
}
