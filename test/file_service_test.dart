import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/services/file_service.dart';

void main() {
  test('recognizes portable KeyWallet vault filenames', () {
    expect(FileService.isVaultFileName('backup.kwvault'), isTrue);
    expect(FileService.isVaultFileName('BACKUP.KWVAULT'), isTrue);
    expect(FileService.isVaultFileName('id_ed25519'), isFalse);
    expect(FileService.isVaultFileName('vault.kwvault.txt'), isFalse);
  });
}
