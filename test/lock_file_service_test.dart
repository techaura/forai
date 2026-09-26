import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/services/lock_file_service.dart';

void main() {
  test('KWVLOCK extraction preserves empty directory entries', () {
    final sourceArchive = Archive()
      ..add(ArchiveFile.directory('A long time ago/'))
      ..add(ArchiveFile.directory('3mfs/'))
      ..add(ArchiveFile.directory('models/'))
      ..add(ArchiveFile.directory('nested/empty/'))
      ..add(ArchiveFile.bytes('nested/file.txt', utf8.encode('hello')));

    final zip = ZipEncoder().encodeBytes(sourceArchive);
    final decoded = ZipDecoder().decodeBytes(zip, verify: true);
    final temp = Directory.systemTemp.createTempSync('kwvlock-empty-dirs-');

    try {
      LockFileService.extractArchivePreservingDirectories(decoded, temp);

      expect(Directory('${temp.path}${Platform.pathSeparator}A long time ago').existsSync(), isTrue);
      expect(Directory('${temp.path}${Platform.pathSeparator}3mfs').existsSync(), isTrue);
      expect(Directory('${temp.path}${Platform.pathSeparator}models').existsSync(), isTrue);
      expect(
        Directory(
          '${temp.path}${Platform.pathSeparator}nested${Platform.pathSeparator}empty',
        ).existsSync(),
        isTrue,
      );
      expect(
        File('${temp.path}${Platform.pathSeparator}nested${Platform.pathSeparator}file.txt')
            .readAsStringSync(),
        'hello',
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('KWVLOCK extraction rejects path traversal', () {
    final archive = Archive()
      ..add(ArchiveFile.bytes('../escape.txt', utf8.encode('nope')));
    final temp = Directory.systemTemp.createTempSync('kwvlock-traversal-');

    try {
      expect(
        () => LockFileService.extractArchivePreservingDirectories(archive, temp),
        throwsA(isA<FormatException>()),
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
